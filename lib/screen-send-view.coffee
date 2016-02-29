{SelectListView} = require 'atom-space-pen-views'

module.exports =
class ScreenSendView extends SelectListView
 initialize: (items, callback) ->
   super
   @callback = callback
   @storeFocusedElement()
   @addClass('overlay from-top')
   @setItems(items)
   @panel ?= atom.workspace.addModalPanel(item: this)
   @panel.show()
   @focusFilterEditor()

 viewForItem: (item) ->
   "<li>#{item}</li>"

 confirmed: (item) ->
   #console.log("#{item} was selected")
   @callback(item)
   @cancel()

 cancelled: ->
   @panel.destroy()
