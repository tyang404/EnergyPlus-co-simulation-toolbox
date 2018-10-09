classdef mlep < mlepSO
%MLEP - EnergyPlus co-simulation tool. 
%The class contains all necesary tools for starting the co-simulation with
%EnergyPlus (E+). It enables data exchanges between the host (in Matlab) and
%the client (the E+ process), using the communication protocol 
%defined by Building Control Virtual Test Bed (BCVTB).
%
%Selected Properties and Methods:
% 
% MLEP Properties:
%         idfFile - Building simulation configuration file for EnergyPlus
%                   .IDF. (Default: 'in.idf')
%         epwFile - Weather data file .EPW. (Default: 'in.epw')
%         workDir - A directory, where the EnergyPlus process is started.
%                   (Default: '.' meaning the current directory)
%   outputDirName - Name of the directory, where all outputs of EnergyPlus 
%                   will be put. The directory is created under the working 
%                   directory. (Default: 'eplusout') 
%           
% MLEP Methods:
%      initialize - Load and validate input files. Write configuration files. 
%           start - Start an EnergyPlus process and establish communication.
%            read - Read outputs from the EnergyPlus. 
%           write - Write inputs to the EnergyPlus.
%            stop - Close communication and terminate the EnergyPlus process.    
%
% MLEP Inherited System Object Methods:
%            step - Send variables 'u' to EnergyPlus and get variables
%                   'y' from EnergyPlus by calling y = step(obj,u).
%                   If useBus = true then 'u' must be an appropriate 
%                   buses/structure and 'y' is a bus/structure, otherwise
%                   'u' and 'y' are vectors of appriate sizes.
%           setup - Initialize system object manually when necessary by 
%                   invoking setup(obj,'init'). The routine will start the 
%                   EnergyPlus process and establish communication. 
%                   The setup routine is called automatically during the 
%                   first 'step' call if not ran manually.
%         release - Equivalent to the stop method.
% 
% Example - Using mlep methods (mlepMatlab_example.m)
%
%     % Initialize
%     ep = mlep;
%     ep.idfFile = 'SmOffPSZ';
%     ep.epwFile = 'USA_IL_Chicago-OHare.Intl.AP.725300_TMY3';
%     ep.start; 
% 
%     % Run
%     u = [20 25];
%     [y, t] = ep.read; % Get EnergyPlus outputs
%     ep.write(u,t);    % Send EnergyPlus inputs
% 
%     % Stop
%     ep.stop;
%
% Example - Using System Object (mlepMatlab_so_example.m)
%
%     % Initialize
%     ep = mlep;
%     ep.idfFile = 'SmOffPSZ';
%     ep.epwFile = 'USA_IL_Chicago-OHare.Intl.AP.725300_TMY3';
%     ep.useBus = false; % use vector I/O
% 
%     % Run
%     u = [20 25];
%     y = ep.step(u); % Communicate with EnergyPlus
%     t = ep.time;
% 
%     % Stop
%     ep.release;
%
% See also: MLEPSO, PROCESSMANAGER
%    
% Copyright (c) 2018, Jiri Dostal (jiri.dostal@cvut.cz)
% All rights reserved.

% Redistribution and use in source and binary forms, with or without
% modification, are permitted provided that the following conditions are 
% met:
%
% 1. Redistributions of source code must retain the above copyright notice,
%    this list of conditions and the following disclaimer.
% 2. Redistributions in binary form must reproduce the above copyright 
%    notice, this list of conditions and the following disclaimer in the 
%    documentation and/or other materials provided with the distribution.
%
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS 
% "AS IS". NO WARRANTIES ARE GRANTED.
%
% History:
%    2009-2013 by Truong Nghiem(truong@seas.upenn.edu)
%    2010-2015 by Willy Bernal(Willy.BernalHeredia@nrel.gov)
%    2018      by Jiri Dostal (jiri.dostal@cvut.cz)
    
    properties (Nontunable)               
        idfFile = 'in.idf';     % Specify IDF file
        epwFile = 'in.epw';     % Specify EPW file                
        workDir = '.';          % Working directory (default is current directory)
        outputDirName = 'eplusout'; % EnergyPlus output directory (created under working folder)                                        
    end
    
    properties (Hidden)                      
    end
    
    properties (SetAccess=private, GetAccess=public)
        timestep;               % Simulation timestep [s] loaded from IDF. 
                                % Timesteps of co-simulation processes must adhere.
        isRunning = false;      % Is co-simulation running?
        isInitialized = false;  % Initialization flag        
        inputTable;             % Table of inputs to EnergyPlus
        outputTable;            % Table of outputs from EnergyPlus       
        versionEnergyPlus;      % EnergyPlus version (identified during intallation)                        
        versionProtocol;        % Current version of the protocol        
    end
    
    properties (Access = private)
        serverSocket;           % Server socket to listen to client
        commSocket;             % Socket for sending/receiving data
        writer;                 % Buffered writer stream
        reader;                 % Buffered reader stream
        process;                % Process object for E+        
        env;                    % Variable containing Environment settings for process run
        program;                % EnergyPlus executable (detected during installation)  
        isUserVarFile;          % True if user-defined variables.cfg file is present        
        idfData;                % Structure with data from parsed IDF
        idfFullFilename;        % Full path to IDF file
        epwFullFilename;        % Full path to EPW file
        iddFullFilename;        % Full path to IDD file
        varFullFilename;        % Full path to variables config file
        outputDirFullPath;      % Full path to the output directory
        epDir;                  % EnergyPlus directory          
    end
    
    properties (Constant, GetAccess = private)       
        rwTimeout = 10000;      % Timeout for sending/receiving data (0 = infinite) [ms]        
        acceptTimeout = 6000;   % Timeout for waiting for the client to connect [ms]                       
        port = 0;               % Socket port (default 0 = any free port)
        host = '';              % Host name (default '' = localhost)
        verboseEP = true;       % Print standard output of the E+ process into Matlab                        
        checkAndKillExistingEPprocesses = 1;       % If selected, mlep will check on startup for other energyplus processes and kill them        
        
        socketConfigFileName = 'socket.cfg';       % Socket configuration file name
        variablesConfigFileName = 'variables.cfg'; % ExternalInterface configuration file name
        iddFile = 'Energy+.idd';                   % IDD file name            
        CRChar = newline;                          % Defined marker by the BCVTB protocol (newline = char(10))
        file_not_found_str = 'Could not find "%s" file. Please correct the file path or make sure it is on the Matlab search path.';
    end
    
    %% =========================== MLEP ===================================
    methods
        function obj = mlep
            loadSettings(obj);
        end % /constructor
        
        function initialize(obj)
            %INITIALIZE - Load and parse all input files, make interface I/O configuration            
            %
            % Syntax:  initialize(obj)
            %
            % See also: START, READ, WRITE, STOP
            
            if obj.isInitialized
                return
            end
            
            if obj.isRunning
                obj.stop;
                obj.isRunning = 0;
            end
            
            % Check parameters
            if isempty(obj.program)
                error('Program name must be specified.');
            end
            
            % Assert files availability
            assert(exist(obj.iddFile,'file')>0,obj.file_not_found_str,obj.iddFile);
            obj.iddFullFilename = which(obj.iddFile);
            obj.idfFullFilename = which(obj.idfFile);
            obj.epwFullFilename = which(obj.epwFile);
            
            % Load IDF file
            obj.loadIdf;            
                        
            % Check IDF version             
            if ~strcmp(obj.versionEnergyPlus,obj.idfData.version{1}{1})
                warning('IDF file of version "%s" is being simulated by an EnergyPlus of version "%s".\n This may cause severe errors in the EnergyPlus simulation.\n Use IDFVersionUpdate utility to upgrade the file (<EP_dir>/PreProcess/IDFVersionUpdater/..).',...
                    obj.idfData.version{1}{1}, obj.versionEnergyPlus);
            end
            
            % Check for possible hanging EP processes
            if obj.checkAndKillExistingEPprocesses
                [~,progname] = fileparts(obj.program);
                mlep.killProcessByName(progname);
            end
            
            % Create E+ output folder
            obj.cleanEP;
            obj.outputDirFullPath = fullfile(obj.workDir,obj.outputDirName);
            [st,ms] = mkdir(obj.outputDirFullPath);
            assert(st,'%s',ms);
            
            % Determine co-simulation inputs and outputs out of IDF or
            % varibles.cfg files
            idfDir = fileparts(obj.idfFullFilename);
            obj.varFullFilename = fullfile(idfDir, obj.variablesConfigFileName);
            obj.isUserVarFile = (exist(obj.varFullFilename,'file') == 2);
            
            if obj.isUserVarFile
                [obj.inputTable, ...
                 obj.outputTable] = mlep.parseVariablesConfigFile(obj.varFullFilename);                
            else
                % Use all the inputs and outputs from IDF
                obj.inputTable = obj.idfData.inputTable;
                obj.outputTable = obj.idfData.outputTable;
            end
            
            % Check I/O configuration
            obj.checkIO;            
            
            % Create or copy ExternalInterface variable configuration file
            obj.makeVariablesConfigFile;
            
            % Stop further initializations
            obj.isInitialized = true;
        end
        
        function start(obj)
            %START - Start the EnergyPlus process and establish connection.
            %
            % Syntax:  start(obj)
            %
            % See also: INITIALIZE, READ, WRITE, STOP
            
            if obj.isRunning, return; end
            
            % Initialize
            obj.initialize;
            
            % Save current directory and change directory if necessary
            changeDir = ~strcmp(obj.workDir,'.');
            if changeDir
                runDir = cd(obj.workDir); % actual dir returned by cd
            else
                runDir = pwd;
            end
            
            try                
                % Create server socket if necessary
                obj.makeSocket;                                   
                
                % Run the EnergyPlus process
                obj.runEnergyPlus;        
                
                % Establish connection
                pause(0.5);
                obj.acceptSocket;
                
            catch ErrObj
                obj.closeSocket;
                if changeDir,cd(runDir); end
                rethrow(ErrObj);
            end
            
            % Revert current folder
            if changeDir,cd(runDir); end
        end
        
        function [outputs, time] = read(obj)
            %READ - Read outputs from the EnergyPlus simulation.
            %
            %  Syntax:   [outputs, time] = read(obj)
            %
            % Outputs:
            %      outputs - Vector of real values sent by EnergyPlus.
            %         time - Time mark sent by EnergyPlus simulation.
            %
            % See also: INITIALIZE, START, WRITE
            
            try
                % Read data from EnergyPlus
                readPacket = obj.readSocket;
                assert( ...
                    ~isempty(readPacket), ...
                    'EnergyPlusCosim:readError', ...
                    'Could not read data from EnergyPlus.' );
                
                % Decode data
                [flag, time, rValOut] = mlep.decodePacket(readPacket);
                outputs = rValOut;
                
                % Process outputs from EnergyPlus
                if flag ~= 0
                    err_str = sprintf('EnergyPlusCosim: EnergyPlus process sent flag "%d" (%s).',...
                        flag, mlep.epFlag2str(flag));
                    if flag < 0
                        [~,errFile] = fileparts(obj.idfFile);
                        errFile = [errFile '.err'];
                        errFilePath = fullfile(pwd,obj.outputDirName,errFile);
                        err_str = [err_str, ...
                            sprintf('Check the <a href="matlab:open %s">%s</a> file for further information.',...
                            errFilePath, errFile)];
                    end
                    error(err_str);
                end
            catch me
                obj.stop;
                rethrow(me);
            end
        end
         
        function write(obj, inputs, time)
            %WRITE - Write inputs to the EnergyPlus simulation.
            %
            %  Syntax:   write(obj, inputs, time)
            %
            %  Inputs:
            %      inputs - Vector of real values to be send to the
            %               EnergyPlus simulation.
            %        time - Time mark to be send to the EnergyPlus simulation.
            %
            % See also: INITIALIZE, START, READ
            
            try
                assert(isa(inputs,'numeric') && isa(time,'numeric'),'Inputs must be a numeric vectors.');
                rValIn = inputs(:);
                % Write data                
                obj.writeSocket(mlep.encodeRealData(obj.versionProtocol,...
                    0, ...
                    time,...
                    rValIn));
            catch me
                obj.stop;
                rethrow(me);                
            end
        end
        
        function stop(obj, stopSignal)
            %STOP - Close communication and stop the EnergyPlus process
            %Send stop to EnergyPlus. Close socket connection. Stop EnergyPlus process.
            %
            % Syntax:  stop(obj)
            %
            % See also: INITIALIZE, START, SETTINGS
            
            if obj.isRunning
                % Send stop signal
                if nargin < 2 || stopSignal                    
                    try 
                        obj.writeSocket(mlep.encodeStatus(obj.versionProtocol, 1));
                    catch 
                        % Connection may already be closed. Socket
                        % exception is a normal behavior                        
                    end
                end
            
                % Close connection
                obj.closeSocket;
            end
            
            if obj.isInitialized 
                % There can be errors prior to "running" status, where the
                % process has already been started
                
                % Destroy process E+
                if isa(obj.process, 'processManager') && obj.process.running
                    obj.process.stop;
                end
            end
            
            obj.isRunning = false;
            obj.isInitialized = false;
        end
    end
    
    methods (Hidden)           
        function delete(obj)
            % Class destructor.
            
            if obj.isRunning
                obj.stop;                 
            end
            obj.isInitialized = false;
            obj.process = [];
            
            % Close server socket
            if isjava(obj.serverSocket)
                obj.serverSocket.close;                
            end
            obj.serverSocket = [];
        end % \destructor
    end
    
    % ---------------------- Get/Set methods ------------------------------
    methods     
        function set.idfFile(obj, file)
            % SET.IDFFILE - Check existance of the IDF file, then set.
           
            if ~isempty(bdroot) && isLibraryMdl(bdroot), return, end
            assert(~isempty(file),'IDF file not specified.');
            assert(ischar(file) || isstring(file),'Invalid file name.');
            if strlength(file)<4 || ~strcmpi(file(end-3:end), '.idf')
                file = [file '.idf']; %add extension
            end
            assert(exist(file,'file')>0,obj.file_not_found_str,file);
            obj.idfFile = file;
        end
        
        function set.epwFile(obj,file)
            % SET.EPWFILE - Check existance of the EPW file, then set.
            
            if ~isempty(bdroot) && isLibraryMdl(bdroot), return, end
            assert(~isempty(file),'EPW file not specified.');
            assert(ischar(file) || isstring(file),'Invalid file name.');
            if strlength(file)<4 || ~strcmpi(file(end-3:end), '.epw')
                file = [file '.epw'];
            end
            assert(exist(file,'file')>0,obj.file_not_found_str,file);
            obj.epwFile = file;
        end
    end
    
    %% ======================== EnergyPlus ================================
    methods (Access = private)
        
        function loadSettings(obj)
            %LOADSETTINGS - Load running environment configuration. 
            %Obtain settings from file MLEPSETTINGS.mat
            %If it doesn't exist run installation.
            %
            % Syntax:  loadSettings(obj)
            %
            % See also: START
            
            % Try to load MLEPSETTING.mat file
            if exist('MLEPSETTINGS.mat','file')
                S = load('MLEPSETTINGS.mat','MLEPSETTINGS');
                mlepSetting = S.MLEPSETTINGS;
                
            elseif exist('installMlep.m', 'file')
                % Run installation script
                installMlep();
                if exist('MLEPSETTINGS.mat','file')
                    S = load('MLEPSETTINGS.mat','MLEPSETTINGS');
                    mlepSetting = S.MLEPSETTINGS;
                else
                    error('Error loading mlep settings. Run "installMlep.m" again and check that the file "MLEPSETTINGS.mat" is in your search path.');                
                end
            else            
                error('Error loading mlep settings. Run "installMlep.m" again and check that the file "MLEPSETTINGS.mat" is in your search path.');            
            end 
            
            if isfield(mlepSetting,'versionProtocol') && ...
                    isfield(mlepSetting,'versionEnergyPlus') && ...
                    isfield(mlepSetting,'program') && ...
                    isfield(mlepSetting,'env') && ...
                    isfield(mlepSetting,'eplusDir') && ...
                    isfield(mlepSetting,'javaDir')
                
                obj.versionProtocol = mlepSetting.versionProtocol;
                obj.versionEnergyPlus = mlepSetting.versionEnergyPlus;
                obj.program = mlepSetting.program;
                obj.env = mlepSetting.env;
                obj.epDir = mlepSetting.eplusDir;
                addpath(mlepSetting.eplusDir);
                addpath(mlepSetting.javaDir);
            else
                error('Error loading mlep settings. Please run "installMlep.m" again.');
            end
        end
        
        function runEnergyPlus(obj)       
            %RUNENERGYPLUS - Start EnergyPlus process.
            %Run EnergyPlus using ProcessManager class. Add listener to
            %process exit event            
            %
            % Syntax:  runEnergyPlus(obj)
            %
            % See also: START
            
            % Set local environment
            for i = 1:numel(obj.env)
                setenv(obj.env{i}{1}, obj.env{i}{2});
            end
            
            % --- Create the external E+ process
            
            % Prepare EP command
            epcmd = javaArray('java.lang.String',11);
            epcmd(1) = java.lang.String(fullfile(obj.epDir,obj.program));
            epcmd(2) = java.lang.String('-w'); % weather file
            epcmd(3) = java.lang.String(obj.epwFullFilename);
            epcmd(4) = java.lang.String('-i'); % IDD file
            epcmd(5) = java.lang.String(obj.iddFullFilename);
            epcmd(6) = java.lang.String('-x'); % expand objects
            epcmd(7) = java.lang.String('-p'); % output prefix
            [~,idfName] = fileparts(obj.idfFile);
            epcmd(8) = java.lang.String(idfName); % output prefix name
            epcmd(9) = java.lang.String('-s'); % output suffix
            epcmd(10) = java.lang.String('D'); % Dash style "prefix-suffix"
            epcmd(11) = java.lang.String(obj.idfFullFilename); % IDF file
            
            epproc = processManager('command',epcmd,...
                'printStdout',obj.verboseEP,...
                'printStderr',obj.verboseEP,...
                'keepStdout',~obj.verboseEP,...
                'keepStderr',~obj.verboseEP,...
                'autoStart', false,... % start process by .start
                'id','EP');     % process ID (also sets stdout prefix)
            epproc.workingDir = obj.outputDirFullPath;
            addlistener(epproc.state,'exit',@epProcListener);
            epproc.start();
            
            if ~epproc.running
                error('Unknown error while starting the EnergyPlus process. Check the *.err file for further information.');
            else
                obj.process = epproc;
            end
            
            function epProcListener(src,data)
                fprintf('\n');
                fprintf('%s: EnergyPlus process exited with exitValue = %d.\n',src.id,src.exitValue);
                
                if src.exitValue ~= 1
                    fprintf('Event name %s\n',data.EventName);
                    fprintf('\n');
                    if ~isempty(src.stdout)
                        fprintf('StdOut of the process:\n\n');
                        processManager.printStream(src.stdout,'StdOut',80);
                    end
                    if ~isempty(src.stderr)
                        fprintf('StdErr of the process:\n\n');
                        processManager.printStream(src.stdout,'StdErr',80);
                    end
                end
                
            end
        end
        
        function loadIdf(obj)
            %LOADIDF - Load I/O variables from the IDF file
            %Read Timestep, RunPeriod, Version and input/output
            %configuration from the specified IDF file. The inputs and
            %outputs are stored into inputTable and outputTable variables.
            %
            % Syntax:  loadIdf(obj)
            %
            % See also: INITIALIZE
            
            % Parse IDF
            in = mlep.readIDF(obj.idfFullFilename,...
                {'Timestep',...
                'RunPeriod',...
                'ExternalInterface:Schedule',...
                'ExternalInterface:Actuator',...
                'ExternalInterface:Variable',...
                'Output:Variable',...
                'Version'});
            obj.idfData.timeStep = str2double(char(in(1).fields{1}));
            obj.timestep = 60/obj.idfData.timeStep * 60; %[s];
            obj.idfData.runPeriod = (str2double(char(in(2).fields{1}(4))) - str2double(char(in(2).fields{1}(2))))*31 + 1 + str2double(char(in(2).fields{1}(5))) - str2double(char(in(2).fields{1}(3)));
            obj.idfData.schedule = in(3).fields;
            obj.idfData.actuator = in(4).fields;
            obj.idfData.variable = in(5).fields;
            obj.idfData.output = in(6).fields;
            obj.idfData.version = in(7).fields;
            
            % List Schedules
            obj.idfData.inputTable = table('Size',[0 2],'VariableTypes',{'string','string'},'VariableNames',{'Name','Type'});
            for i = 1:size(obj.idfData.schedule,2)
                if ~size(obj.idfData.schedule,1)
                    break;
                end
                obj.idfData.inputTable(i,:) = {'schedule',...                % Name
                                                obj.idfData.schedule{i}{1}}; % Type
            end
            
            % List Actuators
            cInput = height(obj.idfData.inputTable);
            for i = 1:size(obj.idfData.actuator,2)
                if ~size(obj.idfData.actuator,1)
                    break;
                end
                obj.idfData.inputTable(cInput+i) = {'actuator',...           % Name
                                                obj.idfData.actuator{i}{1}}; % Type
            end
            
            % List Variable
            cInput = height(obj.idfData.inputTable);
            for i = 1:size(obj.idfData.variable,2)
                if ~size(obj.idfData.variable,1)
                    break;
                end
                obj.idfData.inputTable(cInput+i) = {'variable',...           % Name
                                                obj.idfData.actuator{i}{1}}; % Type
            end
            
            % List Outputs
            obj.idfData.outputTable = table('Size',[0 3],'VariableTypes',{'string','string','string'},'VariableNames',{'Name','Type','Period'});
            for i = 1:size(obj.idfData.output,2)                    
                obj.idfData.outputTable(i,:) = {obj.idfData.output{i}{1}, ... % Name
                                                obj.idfData.output{i}{2}, ... % Type
                                                obj.idfData.output{i}{3}};    % Period
            end
        end
        
        function makeVariablesConfigFile(obj)
            %MAKEVARIABLESCONFIGFILE - Create a variable.cfg config file or reuse user-defined one
            %If there is a variable.cfg in the same directory as the IDF file
            %use it (copy it into the outputFolder for E+ to use).
            %Otherwise, create a new one based on the inputs and outputs
            %defined in the IDF file.
            %
            % Syntax:  makeVariablesConfigFile(obj)
            %
            % See also: MLEP.WRITESOCKETCONFIG, INITIALIZE
            
            if obj.isUserVarFile
                assert(exist(obj.varFullFilename,'file')==2,obj.file_not_found_str,obj.varFullFilename);
                % Copy variables.cfg to the output directory (= working dir for EP)
                if ~copyfile(obj.varFullFilename, obj.outputDirFullPath)
                    error('Cannot copy "%s" to "%s".', obj.varFullFilename, obj.outputDirFullPath);
                end
                newVarFullFilename = fullfile(obj.outputDirFullPath, obj.variablesConfigFileName);
                % Add disclamer to the copied variables.cfg file
                S = fileread(newVarFullFilename);
                disclaimer = [newline '<!--' newline,...
                    '|===========================================================|' newline,...
                    '|                  THIS IS A FILE COPY.                     |' newline,...
                    '| DO NOT EDIT THIS FILE AS ANY CHANGES WILL BE OVERWRITTEN! |' newline,...
                    '|===========================================================|' newline,...
                    '-->' newline];
                anchor = '^<\?xml.*\?>';
                [~,e] = regexp(S,anchor);
                if isempty(e), error('Parsing of "%s" failed. Please check the file.',obj.variablesConfigFileName);
                else
                    S = [S(1:e), disclaimer, S(e+1:end)];
                end
                FID = fopen(newVarFullFilename, 'w');
                if FID == -1, error('Cannot open file "%s".', newVarFullFilename); end
                fwrite(FID, S, 'char');
                fclose(FID);
            else
                % Create a new 'variables.cfg' file based on the input/output
                % definition in the IDF file
                
                mlep.writeVariableConfig(...
                    fullfile(obj.outputDirFullPath, obj.variablesConfigFileName),...
                    obj.inputTable,...
                    obj.outputTable);
                
            end
        end
        
        function checkIO(obj)
            %CHECKIO - Check input/output configuration
            %
            % Syntax:  checkIO(obj)
            %
            % See also: INITIALIZE, MAKEVARIABLESCONFIGFILE
            
            % Check variables.cfg config for wrong entries
            assert(~isempty(obj.inputTable) && ~isempty(obj.outputTable), 'Run parsing of the variables.cfg file first.');
            chk = ismember(obj.inputTable,obj.idfData.inputTable);
            assert(all(chk),'The following inputs to EnergyPlus (ExternalInterface) are defined in the "variables.cfg file, but are missing in the IDF file:\n%s ',...
                evalc('disp(obj.inputTable(~chk,:))'));
            chk = ismember(obj.outputTable,obj.idfData.outputTable);
            assert(all(chk),'The following inputs to EnergyPlus (ExternalInterface) are defined in the "variables.cfg file, but are missing in the IDF file:\n%s ',...
                evalc('disp(obj.outputTable(~chk,:))'));
            
            % Check i/o tables for duplicates
            [obj.inputTable,ia] = unique(obj.inputTable,'rows','stable');
            dupl = setdiff(1:height(obj.inputTable),ia);
            if ~isempty(dupl)
                warning('Omitting the following duplicate input entries:\n%s ',...
                    evalc('disp(obj.inputTable(dupl,:))'));
            end
            [obj.outputTable,ia] = unique(obj.outputTable,'rows','stable');
            dupl = setdiff(1:height(obj.outputTable),ia);
            if ~isempty(dupl)
                warning('IDF file: Omitting the following duplicate output entries:\n%s ',...
                    evalc('disp(obj.outputTable(dupl,:))'));
            end
            
            % Check Outputs for asterisks
            chk = contains(obj.outputTable.Name,'*');
            if any(chk)
               error('IDF file: Ambiguous "*" key value detected in the following entries:\n%sPlease specify the key value exactly (using "Environment", zone name, surface name, etc.).',...
                   evalc('disp(obj.outputTable(chk,:))'));
            end
            
            % Check Outputs for reporting frequency other then 
            chk = contains(obj.outputTable.Period,'timestep','IgnoreCase',true);
            if any(~chk)                
                warning('IDF file: Omitting the following output varibles with reporting frequency other then "timestep":\n%s ',...                    
                    evalc('disp(obj.outputTable(~chk,:))'));
                obj.outputTable = obj.outputTable(chk,:);
            end
        end
        
        function cleanEP(obj)
            %CLEANEP - Delete files from the previous simulation
            %
            % Syntax:  cleanEP(obj)
            %
            % See also: INITIALIZE
            
            % Remove "outputDir" from the "workDir" folder
            if strcmp(obj.workDir,'.')
                rootDir = pwd;
            else
                rootDir = obj.workDir;
            end
            
            dirname = fullfile(rootDir,obj.outputDirName);
            if exist(dirname,'dir')
                mlep.rmdirR(dirname);
            end
        end
    end
    
    methods (Access = private, Static)
        
        function [inputTable, outputTable] = parseVariablesConfigFile(file)
            %PARSEVARIABLESCONFIGFILE - Parse variables.cfg file for the desired I/O.
            %
            % Syntax:  [inputTable, outputTable] = parseVariablesConfigFile(file)
            %
            % Inputs:
            %    file   - Path to the "variables.cfg" file.            
            %
            % Outputs:
            %    inputTable  - Table with parsed inputs.
            %    outputTable - Table with parsed outputs.
            %
            % See also: MLEP, MLEP.MAKEVARIABLESCONFIGFILE
            
            assert(exist(file,'file') > 0,'File "%s" not found.');
            
            inputTable = table('Size',[0 2],'VariableTypes',{'string','string'},'VariableNames',{'Name','Type'});
            cInput = 1;
            outputTable = table('Size',[0 3],'VariableTypes',{'string','string','string'},'VariableNames',{'Name','Type','Period'});
            cOutput = 1;
            
            % Start parsing
            s = xml2struct(file); %modified version of xml2struct allowing for not checking the .dtd file
            s = struct2cell(s);
            vars = s{1}{2}.variable;            
            for i = 1:numel(vars)
                switch vars{i}.Attributes.source
                    % Output from E+
                    case 'EnergyPlus' 
                        out = vars{i}.EnergyPlus.Attributes;
                        assert(isfield(out,'name') && isfield(out,'type'),'Fields "name" and/or "type" are not existing');
                        outputTable(cOutput,:) = {out.name, out.type, 'timestep'};
                        cOutput = cOutput + 1;
                        
                    % Input to E+
                    case 'Ptolemy' 
                        name = fieldnames(vars{i}.EnergyPlus.Attributes);
                        assert(any(contains({'schedule','variable','actuator'},name)),...
                            'Unknown variable name "%s".',name);
                        inputTable(cInput,:) = {name{1}, vars{i}.EnergyPlus.Attributes.(name{1})};                        
                        cInput = cInput + 1;
                    
                    % Error
                    otherwise
                        error('Unknown varible source "%s".',vars{i}.Attributes.source)
                end
            end
        end
        
        function killProcessByName(name, varargin)
            %KILLPROCESSBYNAME - Helper function for killing processes identified by name.
            %
            % Syntax:  killProcessByName(name)
            %
            % Inputs:
            %         name - Name of the process to be killed.
            % issueWarning - Notify when killing processes. (Default: true)
            %
            % See also: MLEP, MLEP.RUNENERGYPLUS
            
            if nargin < 2
                issueWarning = true;
            else
                issueWarning = varargin{1};
                assert(isa(issueWarning,'numeric') || isa(issueWarning,'logical'));
            end
                
            p = System.Diagnostics.Process.GetProcessesByName(name);
            for i = 1:p.Length
                try
                    dt = p(i).StartTime.Now - p(i).StartTime;                    
                    if issueWarning
                        warning('Found process "%s", ID = %d, started %d minutes ago. Terminating the process.',name, p(i).Id, dt.Minutes);                    
                    end
                    p(i).Kill();
                    p(i).WaitForExit(100);
                catch
                    warning('Couldn''t kill process "%s" with ID = %d.',name,p(i).Id);
                    % process was terminating or can't be terminated - deal with it
                    % process has already exited - might be able to let this one go
                end
            end
        end
        
        function rmdirR(dirname)
            %RMDIRR - Helper function for a recursive rmdir
            %
            % Syntax:  rmdirR(dirname)
            %
            % Inputs:
            %      dirname - Directory to be removed. 
            %
            % See also: MLEP, MLEP.INITIALIZE
            
            % Remove foldert recursively (with all files beneath)
            delete(fullfile(dirname,'*'));
            st = rmdir(dirname);
            assert(st,'Could not delete folder "%s".',dirname);
        end
    end
    
    methods (Access = public, Static)
        
        function str = epFlag2str(flag)
            %EPFLAG2STR - Transform numeric flag returned by EnergyPlus into a human readable form.
            % Flag	Description:
            % +1	Simulation reached end time.
            % 0	    Normal operation.
            % -1	Simulation terminated due to an unspecified error.
            % -10	Simulation terminated due to an error during the initialization.
            % -20	Simulation terminated due to an error during the time integration.% 
            %
            % Syntax:  str = epFlag2str(flag)
            %
            % Inputs:
            %         flag - EnergyPlus return flag.
            %
            % Outputs:
            %          str - Flag description.
            %
            % See also: MLEP, MLEP.RUNENERGYPLUS
            
            switch flag
                case 1
                    str = 'Simulation reached end time. If this is not intended, extend the simulation period in the IDF file';
                case 0
                    str = 'Normal operation';
                case -1
                    str = 'Simulation terminated due to an unspecified runtime error';
                case -10
                    str = 'Simulation terminated due to an error during initialization';
                case -20
                    str = 'Simulation terminated due to an error during the time integration';
                otherwise
                    str = sprintf('Unknown flag "%d".',flag);
            end
        end
        
        function [ver, minor] = getEPversion(iddFullpath)
            %GETEPVERSION - Get EnergyPlus version out of Energy+.idd file
            %
            %  Syntax:  [ver, minor] = getEPversion(iddFullpath)
            %
            %  Inputs:
            %  iddFullpath - Path to a .IDD file.  
            %
            % Outputs:
            %          ver - EnergyPlus version (e.g. 8.9)
            %        minor - Last digit of the EnergyPlus version (e.g. 0)
            %
            % See also: MLEP, MLEP.INITIALIZE
            
            % Parse EnergyPlus version out of Energy+.idd file
            assert(exist(iddFullpath,'file')>0,'Could not find "%s" file. Please correct the file path or make sure it is on the Matlab search path.',iddFullpath);
            % Read file
            fid = fopen(iddFullpath);
            if fid == -1, error('Cannot open file "%s".', iddFullpath); end
            str = fread(fid,100,'*char')';
            fclose(fid);
            % Parse the string
            expr = '(?>^!IDD_Version\s+|\G)(\d{1}\.\d{1}|\G)\.(\d+)';
            tokens = regexp(str,expr,'tokens');
            assert(~isempty(tokens)&&size(tokens{1},2)==2,' Error while parsing "%s" for EnergyPlus version',iddFullpath);
            ver = tokens{1}{1};
            minor = tokens{1}{2};
        end
    end
    
    %% ======================= Communication ==============================
    methods (Access = private)
        
        function makeSocket(obj)
            %MAKESOCKET - Create or reuse java socket.
            %Open a socket on a free port on localhost. Make the
            %"socket.cfg" file to be read by BCVTB. 
            %
            %  Syntax:  makeSocket(obj)
            %
            % See also: INITIALIZE, ACCEPTSOCKET
            
            if isempty(obj.serverSocket) || ...
                    (~isempty(obj.serverSocket) && obj.serverSocket.isClosed)
                % If any error happens, this function will be interrupted
                if ~isempty(obj.host)
                    serversock = java.net.ServerSocket(obj.port, 0, obj.host);
                    hostname = obj.host;
                else
                    serversock = java.net.ServerSocket(obj.port);
                    
                    % The following get local host address for incoming connections even
                    % from outside, but it seems unstable, sometimes E+ cannot connect.
                    % hostname = char(getHostName(java.net.InetAddress.getLocalHost));
                    
                    % The following get address that can only be used locally on this
                    % machine, no connections from outside. It may be more stable.
                    hostname = char(getHostName(javaMethod('getLocalHost', 'java.net.InetAddress')));
                    %hostname = char(getHostAddress(serversock.getInetAddress));
                end
                obj.serverSocket = serversock;
            else
                hostname = char(getHostName(javaMethod('getLocalHost', 'java.net.InetAddress')));
                %hostname = char(getHostAddress(serversock.getInetAddress));
            end
            
            % Set accept timeout
            obj.serverSocket.setSoTimeout(obj.acceptTimeout);
            
            % Write socket config file
            mlep.writeSocketConfig(...
                fullfile(obj.outputDirFullPath,obj.socketConfigFileName),...
                hostname,...
                obj.serverSocket.getLocalPort);
            
            obj.commSocket = [];
        end
        
        function acceptSocket(obj)            
            %ACCEPTSOCKET - Establish connection by accepting socket.            
            %
            %  Syntax:  acceptSocket(obj)
            %
            % See also: MAKESOCKET, READSOCKET, WRITESOCKET, CLOSESOCKET,
            %           READ, WRITE
            
            assert(obj.isInitialized, 'Initialize the object first.');
            % Accept Socket
            obj.commSocket = obj.serverSocket.accept;
            
            % Create Streams            
            if isjava(obj.commSocket)
                % Create writer and reader                
                if obj.rwTimeout ~= 0
                    obj.commSocket.setSoTimeout(obj.rwTimeout);
                end
                obj.createStreams;
                obj.isRunning = true;                
            else
                error('Could not establish socket connection. Check that the EnergyPlus process is running and socket configuration.');
            end            
        end
        
        function packet = readSocket(obj)
            %READSOCKET - Read from socket. 
            %
            %  Syntax: packet = readSocket(obj)
            %
            % Outputs: packet - One line of data obtained from the socket.
            %
            % See also: MAKESOCKET, WRITESOCKET
            
            if obj.isRunning
                packet = char(readLine(obj.reader));
%                 packet = char(readLine(java.io.BufferedReader(java.io.InputStreamReader(obj.commSocket.getInputStream))));
            else
                error('Co-simulation is not running.');
            end
        end
        
        function writeSocket(obj, packet)
            %WRITESOCKET - Write data to socket.
            %
            %  Syntax: writeSocket(obj, packet)
            %
            %  Inputs: packet - Data to be sent to the socket.
            %
            % See also: MAKESOCKET, READSOCKET
            
            if obj.isRunning
%                 wr = java.io.BufferedWriter(java.io.OutputStreamWriter(obj.commSocket.getOutputStream));
%                 wr.write(sprintf('%s\n', packet));
%                 wr.flush;
                assert(numel(packet) < 21621);
                obj.writer.write([packet mlep.CRChar]);
                obj.writer.flush;
            else
                error('Co-simulation is not running.');
            end
        end
        
        function setRWTimeout(obj, timeout)
            %SETRWTIMEOUT - Set read/write timeout for the communication socket.
            %
            %  Syntax: setRWTimeout(obj, value)
            %
            %  Inputs: timeout - Communication timeout in [ms].
            %
            % See also: MAKESOCKET, READ, WRITE
            
            if timeout < 0, timeout = 0; end
            obj.rwTimeout = timeout;
            if isjava(obj.commSocket)
                obj.commSocket.setSoTimeout(timeout);
                obj.createStreams;  % Recreate reader and writer streams
            end
        end
        
        function closeSocket(obj)
            %CLOSESOCKET - Close socket connection.            
            %
            %  Syntax: closeSocket(obj)            
            %
            % See also: MAKESOCKET, READ, WRITE
            
            if isjava(obj.serverSocket)
                obj.serverSocket.close();
            end
            
            % Close commSocket
            if isjava(obj.commSocket)
                obj.commSocket.close();
            end
            
            % Close Reader
            if isjava(obj.reader)
                obj.reader.close();
            end
            
            % Close Writer
            if isjava(obj.writer)
                obj.writer.close();
            end
            
            % Delete Java Objects
            obj.reader = [];
            obj.writer = [];
            obj.serverSocket = [];
            obj.commSocket = [];
        end
        
        function createStreams(obj)
            %CREATESTREAMS - Prepare Java I/O streams. 
            %
            %  Syntax: createStreams(obj)   
            %
            % See also: READ, WRITE
            
            obj.writer = java.io.BufferedWriter(java.io.OutputStreamWriter(obj.commSocket.getOutputStream));
            obj.reader = java.io.BufferedReader(java.io.InputStreamReader(obj.commSocket.getInputStream));
        end
    end
    
    methods (Access = private, Static)
        % Decode BCVTB protocol packet
        [flag, timevalue, realvalues, intvalues, boolvalues] = decodePacket(packet);
        
        % Encode BCVTB protocol packet
        packet = encodeData(vernumber, flag, timevalue, realvalues, intvalues, boolvalues);
        
        % Encode BCVTB protocol packet with only real values
        packet = encodeRealData(vernumber, flag, timevalue, realvalues);
        
        % Encode BCVTB protocol simulation status
        packet = encodeStatus(vernumber, flag);
        
        % Parse IDF file
        data = readIDF(filename, classnames);
        
        % Make socket configuration file
        writeSocketConfig(fullFilePath, hostname, port);
        
        % Make co-simulation I/O configuration file
        writeVariableConfig(fullFilePath, inputTable, outputTable);
    end
  
end

