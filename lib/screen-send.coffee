ScreenSendView = require './screen-send-view'
{CompositeDisposable} = require 'atom'
execFileSync = require("child_process").execFileSync
temp = require('temp')
fs = require('fs')

module.exports = ScreenSend =
  screenSendView: null
  subscriptions: null
  session: null

  config:
    terminalType:
      order: 1
      type: "string",
      enum: [
        "iTerm 2"
        "MacOS X Terminal"
        "Konsole"
        "GNU Screen"
        "Tmux"
      ]
      default: "iTerm 2"
    chunkSize:
      order: 2
      description: "Chunk Size in bytes (zero is no chunk size)",
      type: "integer",
      default: 1024,
      minimum: 0
    sleepTime:
      order: 3
      description: "Time to sleep in ms between sending chunks",
      type: "number",
      default: 0,
      minimum: 0

  activate: (state) ->
    @subscriptions = new CompositeDisposable
    @subscriptions.add atom.commands.add 'atom-workspace',
      'screen-send:list': => @list(false)
    @subscriptions.add atom.commands.add 'atom-workspace',
      'screen-send:send': => @send()

  deactivate: ->

  list: (send) ->
    sessions = switch atom.config.get('screen-send.terminalType')
      when 'iTerm 2' then @itermSessions()
      when 'MacOS X Terminal' then @macosxTerminalSessions()
      when 'Konsole' then @konsoleSessions()
      when 'GNU Screen' then @screenSessions()
      when 'Tmux' then @tmuxSessions()
      else throw "Unknown terminal type: #{atom.config.get('screen-send.terminalType')}"

    @screenSendView = new ScreenSendView sessions, (session)=>
      @session = if atom.config.get('screen-send.terminalType') == 'iTerm 2' then @itermGetId(session) else session
      #console.log("list: session=#{@session}")
      @send() if send

  send: ->
    if !@session
      @list(true)
      return
    text = @getSelectedText()
    #console.log("send: session=",@session," text=",{text})

    sleep = atom.config.get('screen-send.sleepTime')

    sendFn = switch atom.config.get('screen-send.terminalType')
      when 'iTerm 2' then @itermSend
      when 'MacOS X Terminal' then @macosxTerminalSend
      when 'Konsole' then @konsoleSend
      when 'GNU Screen' then @screenSend
      when 'Tmux' then @tmuxSend
      else throw "Unknown terminal type: #{atom.config.get('screen-send.terminalType')}"

    @sendText(text, sleep, sendFn)

  sendText: (text, sleep, sendFn) ->
    return if text.length == 0
    sendFn.call(this, text[0])
    return if text.length == 1
    setTimeout ( ->
      @sendText(text.slice(1))
    ), sleep

  getSelectedText: ->
    editor = atom.workspace.getActiveTextEditor()
    pos = editor.getCursorBufferPosition()
    text = editor.getSelectedText()
    if text == ""
      editor.setSelectedBufferRange(editor.getCurrentParagraphBufferRange())
      text = editor.getSelectedText()
      text += "\n" if !text.match(/\n$/)

    editor.getLastSelection().clear()
    editor.setCursorBufferPosition(pos)

    text = text.replace(/^```[^\n]*\n([\s\S]*)```\s*$/, '$1')

    chunkSize = atom.config.get('screen-send.chunkSize')
    chunkSize = text.length if chunkSize < 1

    lines = text.split(/^/m)
    chunks = ['']
    for line in lines
      chunks[chunks.length-1] += line
      chunks.push('') if chunks[chunks.length-1].length >= chunkSize
    return chunks

  macosxTerminalSessions: ->
    stdout = execFileSync 'osascript', ['-e','tell application "Terminal" to tell windows to tell tabs to return tty']
    list = stdout.toString('utf8').replace(/\n$/,'').split(",[ \n]*")
    return list

  macosxTerminalSend: (text) ->
    {path, fd} = temp.openSync('screen-send.')
    fs.write(fd, text)
    execFileSync 'osascript', [
      '-e',"set f to \"#{path}\"",
      '-e','open for access f',
      '-e','set c to (read f)',
      '-e',"tell application \"Terminal\" to do script c in first tab of first window where tty is \"#{@session}\"",
    ]
    fs.unlink(path)

  itermSessions: ->
    stdout = execFileSync 'osascript', ['-e','tell application "iTerm" to tell the terminals to return the sessions']
    list = (item.trim() for item in stdout.toString('utf8').split(","))
    return list

  itermGetId: (session) ->
    stdout = execFileSync 'osascript', ['-e',"tell application \"iTerm\" to tell #{session} to return id"]
    id = stdout.toString('utf8').trim()
    return id

  itermSend: (text) ->
    {path, fd} = temp.openSync('screen-send.')
    fs.write(fd, text)
    #console.log("sending text=", text)
    execFileSync 'osascript', ['-e',"tell application \"iTerm\" to tell terminals to tell session id \"#{@session}\" to write contents of file \"#{path}\""]
    fs.unlink(path)

  konsoleSessions: ->
    stdout = execFileSync 'qdbus', ['org.kde.konsole']
    list = (m.match(/^\/Sessions\/([^\n]+)$/)[1] for m in stdout.toString('utf8').match(/^\/Sessions\/[^\n]+$/gm))
    return list

  konsoleSend: (text) ->
    execFileSync 'qdbus', ['org.kde.konsole',"/Sessions/#{@session}",'sendText',text]

  screenSessions: ->
    stdout = execFileSync 'screen', ['-list']
    list = (m.trim() for m in stdout.toString('utf8').match(/^\s+(\S+)$/gm))
    return list

  screenSend: (text) ->
    {path, fd} = temp.openSync('screen-send.')
    fs.write(fd, text)
    execFileSync 'screen', [
      '-S', @session,
      '-X', 'eval',
      'msgminwait 0',
      'msgwait 0',
      "readbuf \"#{path}\"",
      'paste .',
      'msgwait 5',
      'msgminwait 1',
    ]
    fs.unlink(path)

  tmuxSessions: ->
    stdout = execFileSync 'tmux', ['list-sessions']
    list = (m.replace(/^([^:]*):/,"$1") for m in stdout.toString('utf8').match(/^[^:]*:/gm))
    return list

  tmuxSend: (text) ->
    {path, fd} = temp.openSync('screen-send.')
    fs.write(fd, text)
    execFileSync 'tmux', [
      'load-buffer', path, ';',
      'paste-buffer','-t',@session,';'
    ]
    fs.unlink(path)
