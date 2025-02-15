#[###################### GNU General Public License 3.0 ######################]#
#                                                                              #
#  Copyright (C) 2017─2023 Shuhei Nogawa                                       #
#                                                                              #
#  This program is free software: you can redistribute it and/or modify        #
#  it under the terms of the GNU General Public License as published by        #
#  the Free Software Foundation, either version 3 of the License, or           #
#  (at your option) any later version.                                         #
#                                                                              #
#  This program is distributed in the hope that it will be useful,             #
#  but WITHOUT ANY WARRANTY; without even the implied warranty of              #
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the               #
#  GNU General Public License for more details.                                #
#                                                                              #
#  You should have received a copy of the GNU General Public License           #
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.      #
#                                                                              #
#[############################################################################]#

import std/[strutils, sequtils, options]
import editorstatus, ui, gapbuffer, unicodeext, windownode, movement, editor,
       bufferstatus, settings, registers, messages, commandline,
       independentutils, viewhighlight

proc initSelectedArea*(startLine, startColumn: int): SelectedArea =
  result.startLine = startLine
  result.startColumn = startColumn
  result.endLine = startLine
  result.endColumn = startColumn

proc swapSelectedArea*(area: var SelectedArea) =
  if area.startLine == area.endLine:
    if area.endColumn < area.startColumn:
      swap(area.startColumn, area.endColumn)
  elif area.endLine < area.startLine:
    swap(area.startLine, area.endLine)
    swap(area.startColumn, area.endColumn)

proc swapSelectedAreaVisualLine(
  area: var SelectedArea,
  bufStatus: BufferStatus) =

    if area.endLine < area.startLine:
      swap(area.startLine, area.endLine)

    area.startColumn = 0
    area.endColumn =
      if bufStatus.buffer[area.endLine].high > 0:
        bufStatus.buffer[area.endLine].high
      else:
        0

proc yankBuffer(
  bufStatus: var BufferStatus,
  registers: var Registers,
  windowNode: var WindowNode,
  area: SelectedArea,
  firstCursorPosition: BufferPosition,
  settings: EditorSettings) =

    if area.startLine == area.endLine:
      if bufStatus.buffer[windowNode.currentLine].len < 1:
          # Yank the empty string if the empty line
          registers.setYankedRegister(@[ru""])
      else:
        # Yank the text in the line.
        var yankRunes = ru ""
        let
          endColumn =
            if area.endColumn > bufStatus.buffer[area.startLine].high:
              bufStatus.buffer[area.startLine].high
            else:
              area.endColumn
        for j in area.startColumn .. endColumn:
          yankRunes.add(bufStatus.buffer[area.startLine][j])

        registers.setYankedRegister(yankRunes)
    else:
      var yankLines: seq[Runes]
      for i in area.startLine .. area.endLine:
        if i == area.startLine and area.startColumn > 0:
          yankLines.add(ru"")
          for j in area.startColumn ..< bufStatus.buffer[area.startLine].len:
            yankLines[^1].add(bufStatus.buffer[area.startLine][j])
        elif i == area.endLine and
             area.endColumn < bufStatus.buffer[area.endLine].len:
          yankLines.add(ru"")
          for j in 0 .. area.endColumn:
            yankLines[^1].add(bufStatus.buffer[area.endLine][j])
        else:
          yankLines.add(bufStatus.buffer[i])

      registers.setYankedRegister(yankLines)

    windowNode.moveCursor(firstCursorPosition)

proc yankBufferBlock(
  bufStatus: var BufferStatus,
  registers: var Registers,
  windowNode: WindowNode,
  area: SelectedArea,
  settings: EditorSettings) =

    if bufStatus.buffer.len == 1 and
       bufStatus.buffer[windowNode.currentLine].len < 1: return

    var yankedBuffer: seq[Runes]

    for i in area.startLine .. area.endLine:
      yankedBuffer.add(@[ru ""])
      for j in area.startColumn .. min(bufStatus.buffer[i].high, area.endColumn):
        yankedBuffer[^1].add(bufStatus.buffer[i][j])

    registers.setYankedRegister(yankedBuffer)

proc deleteBuffer(
  bufStatus: var BufferStatus,
  registers: var Registers,
  windowNode: var WindowNode,
  area: SelectedArea,
  firstCursorPosition: BufferPosition,
  settings: EditorSettings,
  commandLine: var CommandLine) =

    if bufStatus.isReadonly:
      commandLine.writeReadonlyModeWarning
      return

    if bufStatus.buffer.len == 1 and
       bufStatus.buffer[windowNode.currentLine].len < 1: return

    bufStatus.yankBuffer(
      registers,
      windowNode,
      area,
      firstCursorPosition,
      settings)

    var currentLine = area.startLine
    for i in area.startLine .. area.endLine:
      let oldLine = bufStatus.buffer[currentLine]
      var newLine = bufStatus.buffer[currentLine]

      if area.startLine == area.endLine:
        if area.endColumn == bufStatus.buffer[area.startLine].len or
           bufStatus.isVisualLineMode:
             # Delete the single line
             bufStatus.buffer.delete(currentLine, currentLine)
        elif oldLine.len > 0:
          # Delete the text in the line.
          for j in area.startColumn .. area.endColumn:
            newLine.delete(area.startColumn)
          if oldLine != newLine: bufStatus.buffer[currentLine] = newLine
        else:
          # Delete the single char
          bufStatus.buffer.delete(currentLine, currentLine)
      elif i == area.startLine and 0 < area.startColumn:
        for j in area.startColumn .. bufStatus.buffer[currentLine].high:
          newLine.delete(area.startColumn)
        if oldLine != newLine: bufStatus.buffer[currentLine] = newLine
        inc(currentLine)
      elif i == area.endLine and area.endColumn < bufStatus.buffer[currentLine].high:
        for j in 0 .. area.endColumn: newLine.delete(0)
        if oldLine != newLine: bufStatus.buffer[currentLine] = newLine
      else: bufStatus.buffer.delete(currentLine, currentLine)

    if bufStatus.buffer.len < 1: bufStatus.buffer.add(ru"")

    if area.startLine > bufStatus.buffer.high:
      windowNode.currentLine = bufStatus.buffer.high
    else: windowNode.currentLine = area.startLine

    let column =
      if bufStatus.buffer[currentLine].high > area.startColumn: area.startColumn
      elif area.startColumn > 0: area.startColumn - 1
      else: 0

    windowNode.currentColumn = column
    windowNode.expandedColumn = column

    inc(bufStatus.countChange)

    bufStatus.isUpdate = true

proc deleteBufferBlock(
  bufStatus: var BufferStatus,
  registers: var Registers,
  windowNode: WindowNode,
  area: SelectedArea,
  settings: EditorSettings,
  commandLine: var CommandLine) =

    if bufStatus.isReadonly:
      commandLine.writeReadonlyModeWarning
      return

    if bufStatus.buffer.len == 1 and
       bufStatus.buffer[windowNode.currentLine].len < 1: return
    bufStatus.yankBufferBlock(
      registers,
      windowNode,
      area,
      settings)

    if area.startLine == area.endLine and bufStatus.buffer[area.startLine].len < 1:
      bufStatus.buffer.delete(area.startLine, area.startLine + 1)
    else:
      var currentLine = area.startLine
      for i in area.startLine .. area.endLine:
        let oldLine = bufStatus.buffer[i]
        var newLine = bufStatus.buffer[i]
        for j in area.startColumn.. min(area.endColumn, bufStatus.buffer[i].high):
          newLine.delete(area.startColumn)
          inc(currentLine)
        if oldLine != newLine: bufStatus.buffer[i] = newLine

    windowNode.currentLine = min(area.startLine, bufStatus.buffer.high)
    windowNode.currentColumn = area.startColumn

    inc(bufStatus.countChange)

    bufStatus.isUpdate = true

proc addIndent(
  bufStatus: var BufferStatus,
  windowNode: WindowNode,
  area: SelectedArea,
  tabStop: int,
  commandLine: var CommandLine) =

    if bufStatus.isReadonly:
      commandLine.writeReadonlyModeWarning
      return

    windowNode.currentLine = area.startLine
    for i in area.startLine .. area.endLine:
      bufStatus.indent(windowNode, tabStop)
      inc(windowNode.currentLine)

    windowNode.currentLine = area.startLine

proc deleteIndent(
  bufStatus: var BufferStatus,
  windowNode: WindowNode,
  area: SelectedArea,
  tabStop: int,
  commandLine: var CommandLine) =

    if bufStatus.isReadonly:
      commandLine.writeReadonlyModeWarning
      return

    windowNode.currentLine = area.startLine
    for i in area.startLine .. area.endLine:
      bufStatus.unindent(windowNode, tabStop)
      inc(windowNode.currentLine)

    windowNode.currentLine = area.startLine

proc insertIndent(
  bufStatus: var BufferStatus,
  area: SelectedArea,
  tabStop: int,
  commandLine: var CommandLine) =

    if bufStatus.isReadonly:
      commandLine.writeReadonlyModeWarning
      return

    for i in area.startLine .. area.endLine:
      let oldLine = bufStatus.buffer[i]
      var newLine = bufStatus.buffer[i]
      newLine.insert(
        ru' '.repeat(tabStop),
        min(area.startColumn,
        bufStatus.buffer[i].high))
      if oldLine != newLine: bufStatus.buffer[i] = newLine

proc replaceCharacter(
  bufStatus: var BufferStatus,
  area: SelectedArea,
  ch: Rune,
  commandLine: var CommandLine) =

    if bufStatus.isReadonly:
      commandLine.writeReadonlyModeWarning
      return

    for i in area.startLine .. area.endLine:
      if bufStatus.buffer[i].len > 0:
        let oldLine = bufStatus.buffer[i]
        var newLine = bufStatus.buffer[i]
        if area.startLine == area.endLine:
          for j in area.startColumn .. area.endColumn: newLine[j] = ch
        elif i == area.startLine:
          for j in area.startColumn .. bufStatus.buffer[i].high: newLine[j] = ch
        elif i == area.endLine:
          for j in 0 .. area.endColumn: newLine[j] = ch
        else:
          for j in 0 .. bufStatus.buffer[i].high: newLine[j] = ch
        if oldLine != newLine: bufStatus.buffer[i] = newLine

    inc(bufStatus.countChange)

proc replaceCharacterBlock(
  bufStatus: var BufferStatus,
  area: SelectedArea,
  ch: Rune,
  commandLine: var CommandLine) =

    if bufStatus.isReadonly:
      commandLine.writeReadonlyModeWarning
      return

    for i in area.startLine .. area.endLine:
      let oldLine = bufStatus.buffer[i]
      var newLine = bufStatus.buffer[i]
      for j in area.startColumn .. min(area.endColumn, bufStatus.buffer[i].high):
        newLine[j] = ch
      if oldLine != newLine: bufStatus.buffer[i] = newLine

proc joinLines(
  bufStatus: var BufferStatus,
  windowNode: WindowNode,
  area: SelectedArea,
  commandLine: var CommandLine) =

    if bufStatus.isReadonly:
      commandLine.writeReadonlyModeWarning
      return

    for i in area.startLine ..< area.endLine:
      windowNode.currentLine = area.startLine
      bufStatus.joinLine(windowNode)

proc toLowerString(
  bufStatus: var BufferStatus,
  windowNode: var WindowNode,
  area: SelectedArea,
  firstCursorPosition: BufferPosition,
  commandLine: var CommandLine) =

    if bufStatus.isReadonly:
      commandLine.writeReadonlyModeWarning
      return

    for i in area.startLine .. area.endLine:
      let oldLine = bufStatus.buffer[i]
      var newLine = bufStatus.buffer[i]
      if oldLine.len == 0: discard
      elif area.startLine == area.endLine:
        for j in area.startColumn .. area.endColumn:
          newLine[j] = oldLine[j].toLower
      elif i == area.startLine:
        for j in area.startColumn .. bufStatus.buffer[i].high:
          newLine[j] = oldLine[j].toLower
      elif i == area.endLine:
        for j in 0 .. area.endColumn: newLine[j] = oldLine[j].toLower
      else:
        for j in 0 .. bufStatus.buffer[i].high: newLine[j] = oldLine[j].toLower
      if oldLine != newLine: bufStatus.buffer[i] = newLine

    inc(bufStatus.countChange)
    windowNode.moveCursor(firstCursorPosition)

proc toLowerStringBlock(
  bufStatus: var BufferStatus,
  windowNode: var WindowNode,
  area: SelectedArea,
  firstCursorPosition: BufferPosition,
  commandLine: var CommandLine) =

    if bufStatus.isReadonly:
      commandLine.writeReadonlyModeWarning
      return

    for i in area.startLine .. area.endLine:
      let oldLine = bufStatus.buffer[i]
      var newLine = bufStatus.buffer[i]
      for j in area.startColumn .. min(area.endColumn, bufStatus.buffer[i].high):
        newLine[j] = oldLine[j].toLower
      if oldLine != newLine: bufStatus.buffer[i] = newLine

    windowNode.moveCursor(firstCursorPosition)

proc toUpperString(
  bufStatus: var BufferStatus,
  windowNode: var WindowNode,
  area: SelectedArea,
  firstCursorPosition: BufferPosition,
  commandLine: var CommandLine) =

    if bufStatus.isReadonly:
      commandLine.writeReadonlyModeWarning
      return

    for i in area.startLine .. area.endLine:
      let oldLine = bufStatus.buffer[i]
      var newLine = bufStatus.buffer[i]
      if oldLine.len == 0: discard
      elif area.startLine == area.endLine:
        for j in area.startColumn .. area.endColumn:
          newLine[j] = oldLine[j].toUpper
      elif i == area.startLine:
        for j in area.startColumn .. bufStatus.buffer[i].high:
          newLine[j] = oldLine[j].toUpper
      elif i == area.endLine:
        for j in 0 .. area.endColumn: newLine[j] = oldLine[j].toUpper
      else:
        for j in 0 .. bufStatus.buffer[i].high: newLine[j] = oldLine[j].toUpper
      if oldLine != newLine: bufStatus.buffer[i] = newLine

    inc(bufStatus.countChange)
    windowNode.moveCursor(firstCursorPosition)

proc toUpperStringBlock(
  bufStatus: var BufferStatus,
  windowNode: var WindowNode,
  area: SelectedArea,
  firstCursorPosition: BufferPosition,
  commandLine: var CommandLine) =

    if bufStatus.isReadonly:
      commandLine.writeReadonlyModeWarning
      return

    for i in area.startLine .. area.endLine:
      let oldLine = bufStatus.buffer[i]
      var newLine = bufStatus.buffer[i]
      for j in area.startColumn .. min(area.endColumn, bufStatus.buffer[i].high):
        newLine[j] = oldLine[j].toUpper
      if oldLine != newLine: bufStatus.buffer[i] = newLine

    windowNode.moveCursor(firstCursorPosition)

proc enterInsertMode(status: var EditorStatus) =
  if currentBufStatus.isReadonly:
    status.commandLine.writeReadonlyModeWarning
  else:
    currentMainWindowNode.currentLine =
      currentBufStatus.selectedArea.get.startLine
    currentMainWindowNode.currentColumn = 0
    status.changeMode(Mode.insert)

proc changeModeToNormalMode(status: var EditorStatus) =
  setBlinkingBlockCursor()
  status.changeMode(Mode.normal)

proc exitVisualMode(status: var EditorStatus) =
  ## Update highlighting and changing mode.

  currentBufStatus.selectedArea = none(SelectedArea)

  var highlight = currentMainWindowNode.highlight
  highlight.updateViewHighlight(
    currentBufStatus,
    currentMainWindowNode,
    status.highlightingText,
    status.settings)

  status.changeModeToNormalMode

proc visualCommand(
  status: var EditorStatus,
  area: var SelectedArea,
  key: Rune) =

    # The position of entered visual mode.
    let firstCursorPosition = BufferPosition(
      line: area.startLine,
      column: area.startColumn)

    if currentBufStatus.isVisualLineMode:
      area.swapSelectedAreaVisualLine(currentBufStatus)
    else:
      area.swapSelectedArea

    if key == ord('y') or isDeleteKey(key):
      currentBufStatus.yankBuffer(
        status.registers,
        currentMainWindowNode,
        area,
        firstCursorPosition,
        status.settings)
    elif key == ord('x') or key == ord('d'):
      currentBufStatus.deleteBuffer(
        status.registers,
        currentMainWindowNode,
        area,
        firstCursorPosition,
        status.settings,
        status.commandLine)
    elif key == ord('>'):
      currentBufStatus.addIndent(
        currentMainWindowNode,
        area,
        status.settings.standard.tabStop,
        status.commandLine)
    elif key == ord('<'):
      currentBufStatus.deleteIndent(
        currentMainWindowNode,
        area,
        status.settings.standard.tabStop,
        status.commandLine)
    elif key == ord('J'):
      currentBufStatus.joinLines(currentMainWindowNode, area, status.commandLine)
    elif key == ord('u'):
      currentBufStatus.toLowerString(
        currentMainWindowNode,
        area,
        firstCursorPosition,
        status.commandLine)
    elif key == ord('U'):
      currentBufStatus.toUpperString(
        currentMainWindowNode,
        area,
        firstCursorPosition,
        status.commandLine)
    elif key == ord('r'):
      let ch = status.getKeyFromMainWindow
      if not isEscKey(ch):
        currentBufStatus.replaceCharacter(area, ch, status.commandLine)
    elif key == ord('I'):
      status.enterInsertMode

    if currentBufStatus.isVisualMode:
      currentBufStatus.selectedArea = none(SelectedArea)
      status.changeMode(currentBufStatus.prevMode)

proc changeModeToInsertMulti(
  status: var EditorStatus,
  area: SelectedArea) =
    ## Rest the current position and changing the mode to the insertMulti mode.

    if currentBufStatus.isReadonly:
      status.commandLine.writeReadonlyModeWarning
      return

    currentMainWindowNode.currentLine = area.startLine
    currentMainWindowNode.currentColumn = area.startColumn

    currentBufStatus.mode = Mode.insertMulti
    changeCursorType(status.settings.standard.insertModeCursor)

proc visualBlockCommand(
  status: var EditorStatus,
  area: var SelectedArea, key: Rune) =

    # The position of entered visual mode.
    let firstCursorPosition = BufferPosition(
      line: area.startLine,
      column: area.startColumn)

    area.swapSelectedArea

    if key == ord('y') or isDeleteKey(key):
      currentBufStatus.yankBufferBlock(
        status.registers,
        currentMainWindowNode,
        area,
        status.settings)
    elif key == ord('x') or key == ord('d'):
      currentBufStatus.deleteBufferBlock(
        status.registers,
        currentMainWindowNode,
        area,
        status.settings,
        status.commandLine)
    elif key == ord('>'):
      currentBufStatus.insertIndent(
        area,
        status.settings.standard.tabStop,
        status.commandLine)
    elif key == ord('<'):
      currentBufStatus.deleteIndent(
        currentMainWindowNode,
        area,
        status.settings.standard.tabStop,
        status.commandLine)
    elif key == ord('J'):
      currentBufStatus.joinLines(currentMainWindowNode, area, status.commandLine)
    elif key == ord('u'):
      currentBufStatus.toLowerStringBlock(
        currentMainWindowNode,
        area,
        firstCursorPosition,
        status.commandLine)
    elif key == ord('U'):
      currentBufStatus.toUpperStringBlock(
        currentMainWindowNode,
        area,
        firstCursorPosition,
        status.commandLine)
    elif key == ord('r'):
      let ch = status.getKeyFromMainWindow
      if not isEscKey(ch):
        currentBufStatus.replaceCharacterBlock(area, ch, status.commandLine)
    elif key == ord('I'):
      status.changeModeToInsertMulti(area)

    if currentBufStatus.isVisualBlockMode:
      currentBufStatus.selectedArea = none(SelectedArea)
      status.changeMode(currentBufStatus.prevMode)

proc isVisualModeCommand*(command: Runes): InputState =
  result = InputState.Invalid

  if command.len == 0:
    return InputState.Continue
  elif command.len == 1:
    let c = command[0]
    if isCtrlC(c) or isEscKey(c) or
       c == ord('h') or isLeftKey(c) or isBackspaceKey(c) or
       c == ord('l') or isRightKey(c) or
       c == ord('k') or isUpKey(c) or
       c == ord('j') or isDownKey(c) or isEnterKey(c) or
       c == ord('^') or
       c == ord('0') or isHomeKey(c) or
       c == ord('$') or isEndKey(c) or
       c == ord('w') or
       c == ord('b') or
       c == ord('e') or
       c == ord('G') or
       c == ord('g') or
       c == ord('{') or
       c == ord('}') or
       c == ord('y') or isDeleteKey(c) or
       c == ord('x') or c == ord('d') or
       c == ord('>') or
       c == ord('<') or
       c == ord('J') or
       c == ord('u') or
       c == ord('U') or
       c == ord('r') or
       c == ord('I'):
         return InputState.Valid

proc execVisualModeCommand*(status: var EditorStatus, command: Runes) =
  ## Execute the visual command and change the mode to a previous mode.

  let key = command[0]

  if isCtrlC(key) or isEscKey(key):
    status.exitVisualMode
  elif key == ord('h') or isLeftKey(key) or isBackspaceKey(key):
    currentMainWindowNode.keyLeft
  elif key == ord('l') or isRightKey(key):
    currentBufStatus.keyRight(currentMainWindowNode)
  elif key == ord('k') or isUpKey(key):
    currentBufStatus.keyUp(currentMainWindowNode)
  elif key == ord('j') or isDownKey(key) or isEnterKey(key):
    currentBufStatus.keyDown(currentMainWindowNode)
  elif key == ord('^'):
    currentBufStatus.moveToFirstNonBlankOfLine(currentMainWindowNode)
  elif key == ord('0') or isHomeKey(key):
    currentMainWindowNode.moveToFirstOfLine
  elif key == ord('$') or isEndKey(key):
    currentBufStatus.moveToLastOfLine(currentMainWindowNode)
  elif key == ord('w'):
    currentBufStatus.moveToForwardWord(currentMainWindowNode)
  elif key == ord('b'):
    currentBufStatus.moveToBackwardWord(currentMainWindowNode)
  elif key == ord('e'):
    currentBufStatus.moveToForwardEndOfWord(currentMainWindowNode)
  elif key == ord('G'):
    currentBufStatus.moveToLastLine(currentMainWindowNode)
  elif key == ord('g') and command.len == 2:
    if command[1] == ord('g'):
      currentBufStatus.moveToFirstLine(currentMainWindowNode)
  elif key == ord('{'):
    currentBufStatus.moveToPreviousBlankLine(currentMainWindowNode)
  elif key == ord('}'):
    currentBufStatus.moveToNextBlankLine(currentMainWindowNode)
  else:
    if isVisualBlockMode(currentBufStatus.mode):
      status.visualBlockCommand(currentBufStatus.selectedArea.get, key)
    else:
      status.visualCommand(currentBufStatus.selectedArea.get, key)
