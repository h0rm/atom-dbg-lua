fs = require 'fs'
path = require 'path'
{BufferedProcess, CompositeDisposable, Emitter} = require 'atom'

escapePath = (path) ->
  return (path.replace /\\/g, '/').replace /[\s\t\n]/g, '\\ '

module.exports = DbgDefold =
  config:
    logToConsole:
      title: 'Log to developer console'
      description: 'For debugging Defold problems'
      type: 'boolean'
      default: false
  logToConsole: true
  dbg: null
  modalPanel: null
  subscriptions: null
  outputPanel: null
  breakpoints: []
  ui: null
  interactiveSession: null
  showOutputPanel: false
  unseenOutputPanelContent: false
  closedNaturally: false
  process: null
  miEmitter: null

  activate: (state) ->
    #require('atom-package-deps').install('dbg-defold')

    atom.config.observe 'dbg-defold.logToConsole', (set) =>
      @logToConsole = set
  consumeOutputPanel: (outputPanel) ->
    @outputPanel = outputPanel

  debug:(options, api) ->
    @ui = api.ui
    @breakpoints = api.breakpoints
    @outputPanel?.clear()

    @start options

    @miEmitter.on 'console', (line) =>
      if @outputPanel
        if @showOutputPanelNext
          @showOutputPanelNext = false
          @outputPanel.show()
        @outputPanel.print '\x1b[37;40m'+line.replace(/([^\r\n]+)\r?\n/,'\x1b[0K$1\r\n')+'\x1b[39;49m', false

    @miEmitter.on 'result', ({type, data}) =>
      switch type
        when 'running'
          @ui.running()

  start: (options) ->
    @showOutputPanel = true
    @unseenOutputPanelContent = false
    @closedNaturally = false
    @outputPanel?.clear()

    command = options.lua_executable||'cmd /C lua'
    cwd = path.resolve options.basedir||'', options.cwd||''

    handleError = (message) =>
      atom.notifications.addError 'Error running Defold Debugger',
        description: message
        dismissable: true

      @ui.stop()

    if @outputPanel and @outputPanel.getInteractiveSession
      interactiveSession = @outputPanel.getInteractiveSession()
      if interactiveSession.pty
        @interactiveSession = interactiveSession

    if @interactiveSession
      @interactiveSession.pty.on 'data', (data) =>
        if @showOutputPanelNext
          @showOutputPanelNext = false
          @outputPanel.show()
        @unseenOutputPanelContent = true

    if @interactiveSession
      @interactiveSession.pty.on 'data', (data) =>
        if @showOutputPanelNext
          @showOutputPanelNext = false
          @outputPanel.show()
        @unseenOutputPanelContent = true

    @miEmitter = new Emitter()
    @process = new BufferedProcess
      command: command
      args: []
      stdout: (data) =>
        if @logToConsole then console.log data
        if @outputPanel
          if @showOutputPanelNext
            @showOutputPanelNext = false
            @outputPanel.show()
          @unseenOutputPanelContent = true
          @outputPanel.print line

      stderr: (data) =>
        if @outputPanel
          if @outputPanelNext
            @showOutputPanelNext = false
            @outputPanel.show()
          @unseenOutputPanelContent = true
          @outputPanel.print line for line in data.replace(/\r?\n$/,'').split(/\r?\n/)

      exit: (data) =>
        @miEmitter.emit 'exit'

    @process.emitter.on 'will-throw-error', (event) =>
      event.handle()

      error = event.error

      if error.code =='ENOENT' && (error.syscall.indexOf 'spawn') == 0
        handleError "Could not find `#{command}`  \nPlease ensure it is correctly installed and available in your system PATH"
      else
        handleError error.message

    @processAwaiting = false
    @processQueued = []

    @sendCommand 'require("mobdebug").listen()'

  stop: ->
    @errorEncountered = null
    @variableObjects = {}
    @variableRootObjects = {}

    @process?.kill()
    @process = null
    @processAwaiting = false
    @processQueued = []

    if @interactiveSession
      @interactiveSession.discard()
      @interactiveSession = null

    if !@closedNaturally or !@unseenOutputPanelContent
      @outputPanel?.hide()

  continue: ->
    @cleanupFrame().then =>
      @sendCommand 'run' .catch(error) =>
        if typeof error != 'string' then return
        @handleMiError error

  pause: ->
    return

  selectFrame: ->
    return

  getVariableChildren: (name) -> return new Promise (fulfill) =>
    fulfill [
      name: ''
      type: ''
      value: ''
      expandable: false
    ]

  stepIn: ->
    @cleanupFrame().then =>
      @sendCommand 'step'.catch(error) =>
        if typeof error != 'string' then return
        @handleMiError error

  stepOut: ->
    @cleanupFrame().then =>
      @sendCommand 'out'.catch(error) =>
        if typeof error != 'string' then return
        @handleMiError error

  stepOver: ->
    @cleanupFrame().then =>
      @sendCommand 'over'.catch(error) =>
        if typeof error != 'string' then return
        @handleMiError error

  sendCommand: (command) ->
    if @processAwaiting
      return new Promise (resolve, reject) =>
        @processQueued.push =>
          @sendCommand command
            .then resolve, reject

    @processAwaiting = true
    promise = Promise.race [
      new Promise (resolve, reject) =>
        event = @miEmitter.on 'result', ({type, data}) =>
          event.dispose()
          # "done", "running" (same as done), "connected", "error", "exit"
          # https://sourceware.org/gdb/onlinedocs/gdb/GDB_002fMI-Result-Records.html#GDB_002fMI-Result-Records
          if type=='error'
            reject data.msg||'Unknown Defold error'
          else
            resolve {type:type, data:data}
      ,new Promise (resolve, reject) =>
        event = @miEmitter.on 'exit', =>
          event.dispose()
          reject 'Debugger terminated'
    ]
    promise.then =>
      @processAwaiting = false
      if @processQueued.length > 0
        @processQueued.shift()()
    , (error) =>
      @processAwaiting = false
      if typeof error != 'string'
        console.error error
      if @processQueued.length > 0
        @processQueued.shift()()

    if @logToConsole then console.log 'dbg-defold > ',command
    @process.process.stdin.write command+'\r\n'
    return promise

    handleMiError: (error, title) ->
      atom.notifications.addError title||'Error received from Defold',
        description:'Defold:\n\n>'+error.trim().split(/\r?\n/).join('\n\n> ')
        dismissable: true

  addBreakpoint: (breakpoint) ->
    @breakpoints.push breakpoint

    @sendCommand 'setb' + (escapePath breakpoint.path)+' '+breakpoint.line
      .catch(error) =>
        if typeof error != 'string' then return
        if error.match /no symbol table is loaded/i
          atom.notifications.addError 'Unable to use breakpoints',
            description: '\nBreakpoints cannot be used.'
            dismissable: true

  removeBreakpoint: (breakpoint) ->
    for i,compare in @breakpoints
      if compare==breakpoint
        @breakpoints.splice i,1

    @sendCommand 'delb' + (escapePath breakpoint.path)+' '+breakpoint.line
      .catch(error) =>
        if typeof error != 'string' then return
        @handleMiError error


  provideDbgProvider: ->
    name: 'dbg-defold'
    description: "Defold debugger"

    canHandleOptions: (options) =>
      return new Promise(fulfill, reject) =>
        @start options
        .then =>
          @stop()
          fulfill true

        .catch (error) =>
          @stop()
          if typeof error == 'string' && error.match /not in executable format/
            fulfill false
          else
            fulfill true

    debug: @debug.bind this
    stop: @stop.bind this

    continue: @continue.bind this
    pause: @pause.bind this

    selectFrame: @selectFrame.bind this
    getVariableChildren: @getVariableChildren.bind this

    stepIn: @stepIn.bind this
    stepOver: @stepOver.bind this
    stepOut: @stepOut.bind this

    addBreakpoint: @addBreakpoint.bind this
    removeBreakpoint: @removeBreakpoint.bind this

  consumeDbg: (dbg) ->
    @dbg = dbg
