classdef Net < handle
%Net
%   A compiled network, ready to be evaluated on some data.
%
%   While Layer objects are used to easily define a network topology
%   (build-time), a Net object compiles them to a format that can be
%   executed quickly (run-time).
%
%   Example:
%      % define topology
%      images = Input() ;
%      labels = Input() ;
%      prediction = vl_nnconv(images, 'size', [5, 5, 1, 3]) ;
%      loss = vl_nnsoftmaxloss(prediction, labels) ;
%
%      % assign names automatically
%      Layer.autoNames() ;
%
%      % compile network
%      net = Net(loss) ;
%
%      % set input data and evaluate network
%      net.setInputs('images', randn(5, 5, 1, 3, 'single'), ...
%                    'labels', single(1:3)) ;
%      net.eval() ;
%
%      disp(net.getValue(loss)) ;
%      disp(net.getDer(images)) ;
%
%   Note: The examples cannot be ran in the <MATCONVNET>/matlab folder
%   due to function shadowing.
%
%   See also LAYER.

% Copyright (C) 2016 Joao F. Henriques.
% All rights reserved.
%
% This file is part of the VLFeat library and is made available under
% the terms of the BSD license (see the COPYING file).

  properties (SetAccess = protected, GetAccess = public)
    forward = []  % forward pass function calls
    backward = []  % backward pass function calls
    test = []  % test mode function calls
    vars = {}  % cell array of variables and their derivatives
    inputs = []  % struct of network's Inputs, indexed by name
    params = []  % list of Params
  end
  properties (SetAccess = public, GetAccess = public)
    meta = []  % optional meta properties
    diagnostics = []  % list of diagnosed vars (see Net.plotDiagnostics)
  end

  methods
    function net = Net(varargin)
      if isscalar(varargin)
        % a single output layer
        root = varargin{1} ;
        
        if ~isa(root, 'Layer')  % convert SimpleNN or DagNN to Layer
          root = Layer(root) ;
        end
      else
        % several output layers; create a dummy layer to hold them together
        root = Layer(@cat, 1, varargin{:}) ;
      end
      
      % figure out the execution order, and list layer objects
      root.resetOrder() ;
      objs = root.buildOrder({}) ;
      
      % get meta properties from one Layer (ideally they should be merged)
      idx = find(cellfun(@(o) ~isempty(o.meta), objs)) ;
      if ~isempty(idx)
        assert(isscalar(idx), 'More than one Layer has the META property.') ;
        net.meta = objs{idx}.meta ;
      end
      
      % figure out the execution order, and list layer objects
      root.resetOrder() ;
      objs = root.buildOrder({}) ;
      
      % automatically set missing names, according to the execution order
      for k = 1:numel(objs)
        if isempty(objs{k}.name)
          if isa(objs{k}, 'Input')  % input1, input2, ...
            n = nnz(cellfun(@(o) isa(o, 'Input'), objs(1:k-1))) ;
            objs{k}.name = sprintf('input%i', n) ;
            
          elseif ~isa(objs{k}, 'Param')  % vl_nnconv1, vl_nnconv2...
            n = nnz(cellfun(@(o) isequal(o.func, objs{k}.func), objs(1:k-1))) ;
            name = func2str(objs{k}.func) ;
            if strncmp(name, 'vl_nn', 5), name(1:5) = [] ; end
            name = strrep(name, '_', '\_') ;
            objs{k}.name = sprintf('%s%i', name, n) ;
            
            % also set dependant Param names: vl_nnconv1_p1, ...
            for i = 1:numel(objs{k}.inputs)
              if isa(objs{k}.inputs{i}, 'Layer') && isempty(objs{k}.inputs{i}.name)
                objs{k}.inputs{i}.name = sprintf('%s_p%i', objs{k}.name, i) ;
              end
            end
          end
        end
      end
      for k = 1:numel(objs)  % name any remaining objects
        if isempty(objs{k}.name)
          n = nnz(cellfun(@(o) isa(o, class(objs{k})), objs(1:k-1))) ;
          objs{k}.name = sprintf('%s%i', lower(class(objs{k})), n) ;
        end
      end
      
      % indexes of callable Layer objects (not Inputs or Params)
      idx = find(cellfun(@(o) ~isa(o, 'Input') && ~isa(o, 'Param'), objs)) ;
      
      % allocate memory
      net.forward = Net.initStruct(numel(idx), 'func', 'name', ...
          'source', 'args', 'inputVars', 'inputArgPos', 'outputVar') ;
      net.test = net.forward ;
      net.backward = Net.initStruct(numel(idx), 'func', 'name', ...
          'source', 'args', 'inputVars', 'inputArgPos', 'numInputDer') ;
      
      % there is one var for the output of each Layer in objs; plus another
      % to hold its derivative. note if a Layer has multiple outputs, they
      % can be stored as a nested cell array in the appropriate var.
      net.vars = cell(2 * numel(objs), 1) ;
      
      numParams = nnz(cellfun(@(o) isa(o, 'Param'), objs)) ;
      net.params = Net.initStruct(numParams, 'name', 'var', ...
          'weightDecay', 'learningRate', 'source', 'trainMethod') ;
      net.inputs = struct() ;
      
      % first, handle Inputs and Params
      p = 1 ;
      for i = 1:numel(objs)
        obj = objs{i} ;
        if isa(obj, 'Input')
          % an input, store its var index by name
          if isempty(obj.name)  % assign a name automatically
            obj.name = sprintf('input%i', numel(fieldnames(net.inputs)) + 1) ;
          end
          assert(~isfield(net.inputs, obj.name), 'An input with the same name already exists.') ;
          net.inputs.(obj.name) = 2 * i - 1 ;
          
        elseif isa(obj, 'Param')
          % a learnable parameter, store them in a list
          net.params(p).var = 2 * i - 1 ;
          net.params(p).name = obj.name ;
          net.params(p).weightDecay = obj.weightDecay ;
          net.params(p).learningRate = obj.learningRate ;
          net.params(p).source = obj.source ;
          
          % store index of training method (defined in Param.trainMethods)
          net.params(p).trainMethod = find(strcmp(obj.trainMethod, Param.trainMethods)) ;
          
          net.vars{net.params(p).var} = obj.value ;  % set initial value
          p = p + 1 ;
        end
      end
      
      % store functions for forward pass
      layer = [] ;
      for k = 1:numel(idx)
        obj = objs{idx(k)} ;
        layer.func = obj.func ;
        layer.name = obj.name ;
        layer.source = obj.source ;
        layer.outputVar = 2 * idx(k) - 1 ;
        net.forward(k) = Net.parseArgs(layer, obj.inputs) ;
      end
      
      % store functions for backward pass
      layer = [] ;
      for k = numel(idx) : -1 : 1
        obj = objs{idx(k)} ;
        
        % add backward function to execution order
        layer.func = autonn_der(obj.func) ;
        layer.name = obj.name ;
        layer.source = obj.source ;
        layer = Net.parseArgs(layer, obj.inputs) ;
        
        % figure out position of derivative argument: it's right before
        % the first string (property-value pair), or at the end if none.
        args = layer.args ;
        for lastInput = 0:numel(args)
          if lastInput < numel(args) && ischar(args{lastInput + 1})
            break
          end
        end
        
        % figure out the number of returned values in bwd mode.
        % assume that the function in bwd mode returns derivatives for
        % all inputs until the last Layer input (e.g. if the 3rd input
        % has class Layer, and others are constants, assume there will be
        % at least 3 output derivatives).
        if isempty(obj.numInputDer)
          layer.numInputDer = max([0, layer.inputArgPos]) ;
        else  % manual override
          layer.numInputDer = obj.numInputDer ;
        end
        
        % store args for backward mode, with an empty slot for der arg
        layer.args = [args(1:lastInput), {[]}, args(lastInput + 1 : end)] ;
        
        % modify argument positions according to the new empty slot
        next = layer.inputArgPos > lastInput ;
        layer.inputArgPos(next) = layer.inputArgPos(next) + 1 ;
        
        % position of der arg
        layer.inputArgPos(end+1) = lastInput + 1 ;
        
        % its var index: it's the output derivative for the current layer
        layer.inputVars(end+1) = 2 * idx(k) ;
        
        net.backward(numel(idx) - k + 1) = layer ;
      end
      
      % store functions for test mode
      layer = [] ;
      for k = 1:numel(idx)
        obj = objs{idx(k)} ;
        
        % add to execution order
        layer.name = obj.name ;
        layer.source = obj.source ;
        layer.outputVar = 2 * idx(k) - 1 ;
        
        % default is to use the same arguments
        if isequal(obj.testInputs, 'same')
          args = obj.inputs ;
        else
          args = obj.testInputs ;
        end
        
        if isempty(obj.testFunc)
          % default is to call the same function as in normal mode
          layer.func = obj.func ;
          
        elseif isequal(obj.testFunc, 'none')
          % layer is pass-through in test mode (e.g. dropout).
          % we don't fully eliminate the layer in test mode because that
          % would require special handling of in/out var indexes.
          layer.func = @deal ;
          args = args(1) ;  % only deal first input
          
        else
          % some other function
          layer.func = obj.testFunc ;
        end
        
        net.test(k) = Net.parseArgs(layer, args) ;
      end
      
      % network outputs, activate diagnostics automatically if empty
      for k = 1:numel(varargin)
        if isempty(varargin{k}.diagnostics)
          varargin{k}.diagnostics = true ;
        end
      end
      
      % store diagnostics info for vars
      valid = false(numel(net.vars), 1) ;
      net.diagnostics = Net.initStruct(numel(net.vars), 'var', 'name') ;
      for k = 1 : numel(objs)
        if isequal(objs{k}.diagnostics, true)
          var = objs{k}.outputVar ;
          net.diagnostics(var).var = var ;
          net.diagnostics(var).name = objs{k}.name ;
          net.diagnostics(var + 1).var = var + 1 ;
          net.diagnostics(var + 1).name = ['\partial', objs{k}.name] ;
          valid([var, var + 1]) = true ;
        end
      end
      net.diagnostics(~valid) = [] ;
    end
    
    function move(net, device)
    %MOVE Move data to CPU or GPU
    %  MOVE(DESTINATION) moves the data associated to the net object OBJ
    %  to either the 'gpu' or the 'cpu'.
      switch device
        case 'gpu', moveOp = @gpuArray ;
        case 'cpu', moveOp = @gather ;
        otherwise, error('Unknown device ''%s''.', device) ;
      end
      
      net.vars = cellfun(moveOp, net.vars, 'UniformOutput',false) ;
    end
    
    function eval(net, mode, derOutput, accumulateParamDers)
      if nargin < 2
        mode = 'normal' ;
      end
      if nargin < 3
        derOutput = single(1) ;
      end
      if nargin < 4
        accumulateParamDers = false ;
      end
      
      % use local variables for efficiency
      vars = net.vars ;
      net.vars = {} ;  % allows Matlab to release memory when needed
      
      switch mode
      case {'normal', 'forward'}  % forward and backward
        forward = net.forward ;   %#ok<*PROPLC> % disable MLint's complaints
      case 'test'  % test mode
        forward = net.test ;
      otherwise
        error('Unknown mode ''%s''.', mode) ;
      end
      
      % forward pass
      for k = 1:numel(forward)
        layer = forward(k) ;
        args = layer.args ;
        args(layer.inputArgPos) = vars(layer.inputVars) ;
        vars{layer.outputVar} = layer.func(args{:}) ;
      end
      
      % backward pass
      if strcmp(mode, 'normal')
        % clear all derivatives. derivatives are even-numbered vars.
        clear = repmat([false; true], numel(vars) / 2, 1);
        if accumulateParamDers  % except for params (e.g. to implement sub-batches)
          clear([net.params.var] + 1) = false ;  % next var is the derivative
        end
        [vars(clear)] = deal({0}) ;
        
        % set root layer's output derivative
        assert(~isempty(derOutput), 'Must specify non-empty output derivatives for normal mode.')
        vars{end} = derOutput ;
        
        backward = net.backward ;
        
        for k = 1:numel(backward)
          % populate function arguments with input vars and derivatives
          layer = backward(k) ;
          args = layer.args ;
          inputArgPos = layer.inputArgPos ;
          args(inputArgPos) = vars(layer.inputVars) ;
          
          if isequal(layer.func, @slice)
            % special case, indexing. the derivative update is sparse.
            % args = {input, slicing indexes, output derivative}.
            inputDer = layer.inputVars(1) + 1 ;  % index of input derivative var
            if isequal(vars{inputDer}, 0)  % must initialize with the right size
              vars{inputDer} = zeros(size(vars{inputDer - 1}), 'like', vars{inputDer - 1}) ;
            end
            vars{inputDer}(args{2}{:}) = vars{inputDer}(args{2}{:}) + args{3} ;
            
          else
            % call function and collect outputs
            out = cell(1, layer.numInputDer) ;
            [out{:}] = layer.func(args{:}) ;
            
            % sum derivatives. the derivative var corresponding to each
            % input comes right next to it in the vars list. note that some
            % outputs may be ignored (because they're not input layers,
            % just constant arguments).
            inputDers = layer.inputVars(1:end-1) + 1 ;  % last input is dzdy, doesn't count
            for i = find(inputArgPos <= numel(out))
              vars{inputDers(i)} = vars{inputDers(i)} + out{inputArgPos(i)} ;
            end
          end
        end
      end
      
      net.vars = vars ;
    end
    
    function value = getValue(net, var)
      if ~isnumeric(var)
        assert(isa(var, 'Layer'), 'VAR must either be var indexes or a Layer object.') ;
        var = var.outputVar ;
      end
      if isscalar(var)
        value = net.vars{var} ;
      else
        value = net.vars(var) ;
      end
    end
    
    
    function der = getDer(net, var)
      if ~isnumeric(var)
        assert(isa(var, 'Layer'), 'VAR must either be var indexes or a Layer object.') ;
        var = var.outputVar ;
      end
      if isscalar(var)
        der = net.vars{var + 1} ;
      else
        der = net.vars(var + 1) ;
      end
    end
    
    function setValue(net, var, value)
      if ~isnumeric(var)
        assert(isa(var, 'Layer'), 'VAR must either be var indexes or a Layer object.') ;
        var = var.outputVar ;
      end
      if isscalar(var)
        net.vars{var} = value ;
      else
        net.vars(var) = value ;
      end
    end
    
    function setDer(net, var, der)
      if ~isnumeric(var)
        assert(isa(var, 'Layer'), 'VAR must either be var indexes or a Layer object.') ;
        var = var.outputVar ;
      end
      if isscalar(var)
        net.vars{var + 1} = der ;
      else
        net.vars(var + 1) = der ;
      end
    end
    
    function setInputs(net, varargin)
      assert(mod(numel(varargin), 2) == 0, ...
        'Arguments must be in the form INPUT1, VALUE1, INPUT2, VALUE2,...'),
      
      for i = 1 : 2 : numel(varargin) - 1
        net.vars{net.inputs.(varargin{i})} = varargin{i+1} ;
      end
    end
    
    function plotDiagnostics(net, numPoints)
      fig = findobj(0, 'Type','figure', 'Tag', 'Net.plotDiagnostics') ;
      if isempty(fig)
        fig = figure() ;
        if isequal(fig, 1) || isequal(get(fig, 'Number'), 1)
          fig = figure() ;  % avoid using figure 1, since it's used by cnn_train
        end
        s = [] ;
      else
        s = get(fig, 'UserData') ;
      end
      n = numel(net.diagnostics) ;
      
      if ~isstruct(s) || ~isfield(s, 'diagnostics') || ~isequal(s.diagnostics, net.diagnostics) || ...
        ~isequal(s.numPoints, numPoints) || ~all(ishandle([s.ax, s.lines, s.patches]))
        clf ;  % initialize new figure, with n axes
        s = [] ;
        s.diagnostics = net.diagnostics ;
        s.numPoints = numPoints ;
        colors = get(0, 'DefaultAxesColorOrder') ;
        if n < 4  % vertical layout
          m = n ;
          w = 1 ;
        else  % 2-columns layout
          m = ceil(n / 2) ;
          w = 0.5 ;
        end
        for i = 1:n
          if i <= m
            s.ax(i) = axes('OuterPosition', [0, 1-i/m, w, 1/m]) ;
          else
            s.ax(i) = axes('OuterPosition', [w, 1-(i-m)/m, w, 1/m]) ;
          end
          
          color = colors(mod(floor((i-1)/2), size(colors,1)) + 1, :) ;
          s.lines(i) = line(1:numPoints, NaN(1, numPoints), 'Color', color);
          
          s.mins{i} = NaN(1, numPoints) ;
          s.maxs{i} = NaN(1, numPoints) ;

          s.patches(i) = patch('XData', [], 'YData', [], 'EdgeColor', 'none', 'FaceColor', color, 'FaceAlpha', 0.5) ;
        
          set(s.ax(i), 'XLim', [1, numPoints], 'XTickLabel', {' '}, 'FontSize', 8) ;
          ylabel(net.diagnostics(i).name) ;
        end
        set(fig, 'Tag', 'Net.plotDiagnostics', 'UserData', s) ;
      end
      
      % add new points and roll buffer
      for i = 1:n
        data = net.vars{net.diagnostics(i).var}(:) ;
        ps = get(s.lines(i), 'YData') ;
        ps = [ps(2:end), gather(mean(data))] ;
        set(s.lines(i), 'YData', ps) ;
        
        if ~all(isnan(ps))
          if ~isscalar(data)
            mi = gather(min(data)) ;
            ma = gather(max(data)) ;
            if mi ~= ma
              s.mins{i} = [s.mins{i}(2:end), mi] ;
              s.maxs{i} = [s.maxs{i}(2:end), ma] ;
            
              valid = find(~isnan(s.mins{i})) ;
              set(s.patches(i), 'XData', [valid, valid(end:-1:1)], ...
                'YData', [s.mins{i}(valid), s.maxs{i}(valid(end:-1:1))]) ;
              set(s.ax(i), 'YLim', [min(s.mins{i}), max(s.maxs{i})]) ;
            end
          else
            set(s.ax(i), 'YLim', [min(ps), max(ps) + 0.01 * abs(max(ps))]) ;
          end
        end
      end
      set(fig, 'UserData', s) ;
      drawnow ;
    end
    
    function displayVars(net, vars)
      % get information on each var, and corresponding derivative
      if nargin < 2
        vars = net.vars ;
      end
      n = numel(vars) / 2 ;
      assert(n ~= 0, 'NET.VARS is empty.') ;
      type = cell(n, 1) ;
      names = cell(n, 1) ;
      funcs = cell(n, 1) ;
      
      % vars that correspond to inputs
      inputNames = fieldnames(net.inputs);
      for k = 1:numel(inputNames)
        idx = (net.inputs.(inputNames{k}) + 1) / 2 ;
        type{idx} = 'Input' ;
        names{idx} = inputNames{k} ;
      end
      
      % vars that correspond to params
      idx = ([net.params.var] + 1) / 2 ;
      [type{idx}] = deal('Param') ;
      names(idx) = {net.params.name} ;
      
      % vars that correspond to layer outputs
      idx = ([net.forward.outputVar] + 1) / 2 ;
      [type{idx}] = deal('Layer') ;
      names(idx) = {net.forward.name} ;
      funcs(idx) = cellfun(@func2str, {net.forward.func}, 'UniformOutput', false) ;
      
      % get Matlab to print the values nicely (e.g. "[50x1 double]")
      values = strsplit(evalc('disp(vars)'), '\n') ;
      values = cellfun(@strtrim, values, 'UniformOutput', false) ;
      
      % now print out the info as a table
      str = repmat(' ', n + 1, 1) ;
      str = [str, char('Type', type{:})] ;
      str(:,end+1:end+2) = ' ' ;
      str = [str, char('Function', funcs{:})] ;
      str(:,end+1:end+2) = ' ' ;
      str = [str, char('Name', names{:})] ;
      str(:,end+1:end+2) = ' ' ;
      str = [str, char('Value', values{1 : 2 : 2 * n})] ;
      str(:,end+1:end+2) = ' ' ;
      str = [str, char('Derivative', values{2 : 2 : 2 * n})] ;
      
      disp(str) ;
    end
    
    function display(net, name)
      if nargin < 2
        name = inputname(1) ;
      end
      fprintf('\n%s = \n', name) ;
      disp(net) ;
      
      if ~isempty(name)
        fprintf('  <a href="matlab:%s.displayVars()">Display variables</a>\n\n', name) ;
      end
    end
    
    function s = saveobj(net)
      s.forward = net.forward ;
      s.backward = net.backward ;
      s.test = net.test ;
      s.inputs = net.inputs ;
      s.params = net.params ;
      s.meta = net.meta ;
      s.diagnostics = net.diagnostics ;
      
      % only save var contents corresponding to parameters, all other vars
      % are transient
      s.vars = cell(size(net.vars)) ;
      s.vars([net.params.var]) = net.vars([net.params.var]) ;
    end
  end
  
  methods (Static)
    function net = loadobj(s)
      net.forward = s.forward ;
      net.backward = s.backward ;
      net.test = s.test ;
      net.vars = s.vars ;
      net.inputs = s.inputs ;
      net.params = s.params ;
      net.meta = s.meta ;
      net.diagnostics = s.diagnostics ;
    end
  end
  
  methods (Static, Access = private)
    function layer = parseArgs(layer, args)
      % helper function to parse a layer's arguments, storing the constant
      % arguments (args), non-constant var indexes (inputVars), and their
      % positions in the arguments list (inputArgPos).
      inputVars = [] ;
      inputArgPos = [] ;
      for a = 1:numel(args)
        if isa(args{a}, 'Layer')
          inputVars(end+1) = args{a}.outputVar ;  %#ok<*AGROW>
          inputArgPos(end+1) = a ;
          args{a} = [] ;
        end
      end
      layer.args = args ;
      layer.inputVars = inputVars ;
      layer.inputArgPos = inputArgPos ;
      layer = orderfields(layer) ;  % have a consistent field order, to not botch assignments
    end
    
    function s = initStruct(n, varargin)
      % helper function to initialize a struct with given fields and size.
      % note fields are sorted in ASCII order (important when assigning
      % structs).
      varargin(2,:) = {cell(1, n)} ;
      s = orderfields(struct(varargin{:})) ;
    end
  end
end

