-- #700 live probe: what does Mail show after a reply is sent with the send keystroke?
--
-- It replies to ONE message (given as an AppleScript reference in the first
-- argument) and SENDS that reply, so the target must be a test message whose
-- only sender and recipient is the maintainer. It then samples, every 0.5 s
-- for 20 s, the signals a send confirmation could use, and returns them as
-- text. It closes nothing and retries nothing.
--
-- Run:  osascript probe.applescript '<message reference>' '<body text>' '<only allowed address>'
-- Needs Automation (Mail, System Events) and Accessibility for the process
-- that runs osascript.
--
-- Recipient gate: after Mail builds the reply and before anything is typed, the
-- script reads the reply's To, Cc and Bcc. It goes on only when there is at
-- least one To address and every address equals the third argument (compared
-- without case). Otherwise it stops with an error; the reply window is left
-- open and unsent for the person running it to close.

on run argv
	if (count of argv) is not 3 then error "usage: probe.applescript <message reference> <body text> <only allowed address>"
	set _refText to item 1 of argv
	set _body to item 2 of argv
	set _allowed to item 3 of argv
	if _allowed does not contain "@" then error "the third argument must be an email address"
	set _log to {}

	-- Resolve the reference outside the Mail block: inside it, `run` is Mail's own command.
	set originalMsg to run script ("tell application \"Mail\" to return " & _refText)
	tell application "Mail"
		set _beforeIds to (id of every window)
		set _outBefore to (count of outgoing messages)
		set replyMsg to reply originalMsg with opening window
	end tell
	delay 1.8
	-- Recipient gate (see the header). Nothing has been typed or sent yet.
	tell application "Mail"
		set _toAddrs to (address of every to recipient of replyMsg)
		set _ccAddrs to (address of every cc recipient of replyMsg)
		set _bccAddrs to (address of every bcc recipient of replyMsg)
	end tell
	if (count of _toAddrs) is 0 then error "recipient gate: the reply has no To address; nothing was typed or sent"
	ignoring case
		repeat with _a in (_toAddrs & _ccAddrs & _bccAddrs)
			if (contents of _a) is not _allowed then error "recipient gate: the reply has a recipient other than the allowed address; nothing was typed or sent"
		end repeat
	end ignoring
	set end of _log to "recipients: to=" & (count of _toAddrs) & " cc=" & (count of _ccAddrs) & " bcc=" & (count of _bccAddrs) & " (all equal the allowed address)"
	tell application "Mail"
		set _afterIds to (id of every window)
		set _newIds to {}
		repeat with _k from 1 to (count of _afterIds)
			set _thisId to item _k of _afterIds
			if _beforeIds does not contain _thisId then set end of _newIds to _thisId
		end repeat
		if (count of _newIds) is 0 then error "reply did not open a compose window"
		set _frontId to (id of front window)
		if _frontId is not in _newIds then error "the reply window is not frontmost; nothing was typed or sent"
		set _replyId to missing value
		try
			set _replyId to (id of replyMsg)
		end try
		set end of _log to "before: windows=" & (count of _beforeIds) & " outgoing=" & _outBefore
		set end of _log to "opened: newWindowIds=" & my joined(_newIds) & " frontId=" & _frontId & " replyMsgId=" & (_replyId as text) & " outgoing=" & (count of outgoing messages)
	end tell

	tell application "System Events"
		tell process "Mail"
			set frontmost to true
			delay 0.25
			set the clipboard to _body
			keystroke "v" using command down
			delay 0.7
		end tell
	end tell

	tell application "Mail"
		if (id of front window) is not _frontId then error "focus changed before the send keystroke; nothing was sent"
	end tell
	tell application "System Events"
		tell process "Mail"
			set frontmost to true
			delay 0.25
			if (count of sheets of window 1) is not 0 then error "a sheet is open on the compose window; nothing was sent"
			keystroke "d" using {command down, shift down}
		end tell
	end tell
	set _t0 to (current date)

	repeat with _i from 1 to 40
		delay 0.5
		set _windowListed to "?"
		set _msgExists to "?"
		set _outCount to "?"
		set _sheets to "?"
		try
			tell application "Mail"
				set _nowIds to (id of every window)
				set _windowListed to (_nowIds contains _frontId) as text
				set _outCount to (count of outgoing messages) as text
				try
					set _msgExists to (exists replyMsg) as text
				on error _e
					set _msgExists to "error: " & _e
				end try
			end tell
		on error _e2
			set _windowListed to "query error: " & _e2
		end try
		try
			tell application "System Events" to tell process "Mail" to set _sheets to (count of sheets of window 1) as text
		end try
		set end of _log to "t+" & (_i * 0.5) & "s windowListed=" & _windowListed & " replyMsgExists=" & _msgExists & " outgoing=" & _outCount & " frontWindowSheets=" & _sheets
	end repeat

	set AppleScript's text item delimiters to linefeed
	set _text to _log as text
	set AppleScript's text item delimiters to ""
	return _text
end run

on joined(_list)
	set _out to ""
	repeat with _x in _list
		set _out to _out & (contents of _x) & " "
	end repeat
	return _out
end joined
