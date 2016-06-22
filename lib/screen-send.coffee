ScreenSendView = require './screen-send-view'
{CompositeDisposable, Range} = require 'atom'
execFileSync = require("child_process").execFileSync
temp = require('temp')
fs = require('fs')

module.exports = ScreenSend =
  screenSendView: null
  subscriptions: null
  session: {}

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
      default: 512,
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
      bufid = atom.workspace.getActiveTextEditor().getBuffer().getId()
      @session[bufid] = session
      #console.log("list: session=#{@session}")
      @send() if send

  send: ->
    bufid = atom.workspace.getActiveTextEditor().getBuffer?().getId()
    if !@session[bufid]
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

    @sendText(text, sleep, sendFn, @session[bufid])

  sendText: (text, sleep, sendFn, session) ->
    return if text.length == 0
    sendFn.call(this, text[0], session)
    return if text.length == 1
    setTimeout ( =>
      @sendText(text.slice(1), sleep, sendFn, session)
    ), sleep

  getSelectedText: ->
    editor = atom.workspace.getActiveTextEditor()
    pos = editor.getCursorBufferPosition()
    text = editor.getSelectedText()
    if text == ""
      editor.setSelectedBufferRange(@rowRangeForParagraphAtBufferRow(editor, pos.row))
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

  # Find a row range for a 'paragraph' around specified bufferRow. A paragraph
  # is a block of text bounded by and empty line.
  # Adapted from: https://github.com/atom/atom/blob/master/src/language-mode.coffee
  rowRangeForParagraphAtBufferRow: (editor, bufferRow) ->
    return unless /\S/.test(editor.lineTextForBufferRow(bufferRow))
    [firstRow, lastRow] = [0, editor.getLastBufferRow()-1]

    startRow = bufferRow
    while startRow > firstRow
      break unless /\S/.test(editor.lineTextForBufferRow(startRow - 1))
      startRow--

    endRow = bufferRow
    lastRow = editor.getLastBufferRow()
    while endRow < lastRow
      break unless /\S/.test(editor.lineTextForBufferRow(endRow + 1))
      endRow++

    new Range([startRow, 0], [endRow, editor.lineTextForBufferRow(endRow).length])

  macosxTerminalSessions: ->
    stdout = execFileSync 'osascript', ['-e','tell application "Terminal" to tell windows to tell tabs to return tty']
    list = stdout.toString('utf8').replace(/\n$/,'').split(",[ \n]*")
    return list

  macosxTerminalSend: (text, session) ->
    {path, fd} = temp.openSync('screen-send.')
    fs.write(fd, text)
    execFileSync 'osascript', [
      '-e',"set f to \"#{path}\"",
      '-e','open for access f',
      '-e','set c to (read f)',
      '-e',"tell application \"Terminal\" to do script c in first tab of first window where tty is \"#{session}\"",
    ]
    fs.unlink(path)

  itermSessions: ->
    stdout = execFileSync 'osascript', ['-e','tell application "iTerm" to tell windows to tell tabs to return sessions']
    list = (item.trim() for item in stdout.toString('utf8').split(","))
    return list

  itermSend: (text, session) ->
    session = session.replace(/session id (\S+)/, 'session id "$1"')
    session = session.replace(/window id (\S+)/, 'window id "$1"')
    {path, fd} = temp.openSync('screen-send.')
    fs.write(fd, text)
    #console.log("sending text=", text)
    execFileSync 'osascript', ['-e',"tell application \"iTerm\" to tell #{session} to write contents of file \"#{path}\""]
    fs.unlink(path)

  konsoleSessions: ->
    stdout = execFileSync 'qdbus', ['org.kde.konsole*']
    konsole = stdout.toString('utf8').split(/\r?\n/)
    list = []
    for k in konsole
      if k
        stdout = execFileSync 'qdbus', [k]
        input = stdout.toString('utf8')
        matches = []; regex = /^\/Sessions\/([^\n]+)$/gm
        list.push(k+"\t"+matches[1]) while matches = regex.exec(input)
    return list

  konsoleSend: (text, session) ->
    [k, s] = session.split("\t")
    execFileSync 'qdbus', [k,"/Sessions/#{s}",'sendText',text]

  screenSessions: ->
    stdout = execFileSync 'screen', ['-list']
    input = stdout.toString('utf8')
    matches = []; list = []; regex = /^\s+(\S+)/gm
    list.push(matches[1]) while matches = regex.exec(input)
    return list

  screenSend: (text, session) ->
    {path, fd} = temp.openSync('screen-send.')
    fs.write(fd, text)
    execFileSync 'screen', [
      '-S', session,
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
    input = stdout.toString('utf8')
    matches = []; list = []; regex = /^([^:]*):/gm
    list.push(matches[1]) while matches = regex.exec(input)
    return list

  tmuxSend: (text, session) ->
    {path, fd} = temp.openSync('screen-send.')
    fs.write(fd, text)
    execFileSync 'tmux', [
      'load-buffer', path, ';',
      'paste-buffer','-t',session,';'
    ]
    fs.unlink(path)
