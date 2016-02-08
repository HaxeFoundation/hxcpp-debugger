/** **************************************************************************
 * CommandLineController.hx
 *
 * Copyright 2013 TiVo Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 ************************************************************************** **/

package debugger;

import debugger.IController;


/**
 * This class implements a command line interface to a debugger.  It
 * implements IController so that it can be used directly by a debugger
 * thread, or can be used by a proxy class.  This interface reads from stdin
 * and writes to stdout.  It supports history commands, sourcing files, and
 * some other niceties.
 **/
class CommandLineController implements IController
{
    /**
     * Creates a new command line interface.  This interface will read and
     * parse Commands from stdin, and emit debugger output to stdout.
     **/
    public function new()
    {
        Sys.println("");
        Sys.println("-=- hxcpp built-in debugger in command line mode -=-");
        Sys.println("-=-      Use 'help' for help if you need it.     -=-");
        Sys.println("-=-                  Have fun!                   -=-");
        mUnsafeMode = false;
        mInputs = new Array<haxe.io.Input>();
        mInputs.push(Sys.stdin());
        mStoredCommands = new Array<String>();
        mLastCommand = null;
        // Command 0 is not valid
        mStoredCommands.push("");
        this.setupRegexHandlers();
    }

    // Called when the process being debugged has started again
    public function debuggedProcessStarted()
    {
        Sys.println("Attached to debugged process.");
        // xxx todo - re-issue breakpoint commands from history?
        // Or maybe at the very least support a command that does this?
    }

    // Called when the process being debugged has exited
    public function debuggedProcessExited()
    {
        Sys.println("Debugged process exited.");
    }

    public function getNextCommand() : Command
    {
        var carriedCommandLine : String = "";

        while (true) {
            var input = mInputs[mInputs.length - 1];

            if (mInputs.length == 1) {
                Sys.print("\n" + mStoredCommands.length + "> " +
                          carriedCommandLine);
            }

            var commandLine = null;

            try {
                commandLine = StringTools.trim(carriedCommandLine +
                                               input.readLine());
                carriedCommandLine = "";
            }
            catch (e : haxe.io.Eof) {
                Sys.println("\n");
                input.close();
                mInputs.pop();
                if (mInputs.length == 0) {
                    return Detach;
                }
                else {
                    continue;
                }
            }

            if (mInputs.length == 1) {
                Sys.println("");
            }

            // If the command line ends with "\", don't execute the command,
            // just append it to the carriedCommandLine.  This is to assist
            // when program or thread event output has confused the user and
            // they wish to continue the command in progress.

            if (StringTools.endsWith(commandLine, "\\")) {
                carriedCommandLine =
                    commandLine.substr(0, commandLine.length - 1);
                continue;
            }

            // If the line is empty, the skip it unless the input is
            // stdin and the last command was one of the commands that
            // is repeated automatically (continue, step, next, finish, up,
            // and down)
            if (commandLine.length == 0) {
                // If reading from a sourced file or this is the first
                // command, don't try to repeat
                if ((mInputs.length > 1) || (mLastCommand == null)) {
                    continue;
                }
                switch (mLastCommand) {
                case Continue(n):
                case Step(n):
                case Next(n):
                case Finish(n):
                case Up(n):
                case Down(n):
                default:
                    // For anything other than the above, read a new command
                    continue;
                }
                // For Continue, Step, Next, Finish, Up, or Down, repeat
                return mLastCommand;
            }

            var charZero = commandLine.charAt(0);

            // If the command is a comment, do nothing
            if (charZero == "#") {
                continue;
            }

            if (mInputs.length != 1) {
                Sys.println("\n" + mStoredCommands.length + "> " + commandLine);
            }

            // If it's a bang command, replace it with the stored command
            if (charZero == "!") {
                var number =
                    Std.parseInt(StringTools.trim(commandLine.substr(1)));
                if ((number <= 0) || (number >= mStoredCommands.length)) {
                    Sys.println("No command " + number + " in history.");
                    continue;
                }
                commandLine = mStoredCommands[number];
                // Print out the command line to show what is being run
                Sys.println(number + ") " + commandLine);
            }
            else {
                mStoredCommands.push(commandLine);
            }

            var command : Command = null;

            var matched = false;

            for (rh in mRegexHandlers) {
                if (rh.r.match(commandLine)) {
                    command = rh.h(rh.r);
                    matched = true;
                    break;
                }
            }

            if (!matched) {
                Sys.println("Invalid command./178");
                continue;
            }

            if (command != null) {
                // Instruction was not handled locally, so pass it on to the
                // debugger
                mLastCommand = command;
                return command;
            }
        }
    }

    public function acceptMessage(message : Message)
    {
        // This makes the output of the 'source' command look a little better
        if (mInputs.length > 1) {
            Sys.println("");
        }

        switch (message) {
        case ErrorInternal(details):
            Sys.println("Debugged thread reported internal error: " + details);

        case ErrorNoSuchThread(number):
            Sys.println("No such thread " + number + ".");

        case ErrorNoSuchFile(fileName):
            Sys.println("No such file " + fileName + ".");

        case ErrorNoSuchBreakpoint(number):
            Sys.println("No such breakpoint " + number + ".");

        case ErrorBadClassNameRegex(details):
            Sys.println("Invalid class name regular expression: " +
                        details + ".");

        case ErrorBadFunctionNameRegex(details):
            Sys.println("Invalid function name regular expression: " +
                        details + ".");

        case ErrorNoMatchingFunctions(className, functionName,
                                      unresolvableClasses):
            Sys.println("No functions matching " + className + "." +
                        functionName + ".");
            printUnresolvableClasses(unresolvableClasses);

        case ErrorBadCount(count):
            Sys.println("Bad count " + count + ".");

        case ErrorCurrentThreadNotStopped(threadNumber):
            Sys.println("Current thread " + threadNumber + " not stopped.");

        case ErrorEvaluatingExpression(details):
            Sys.println("Failed to evaluate expression: " + details);

        case OK:
            // This message is just sent as a way to say that commands that
            // don't have any status were received

        case Exited:
            Sys.println("Debugged process has exited.");

        case Detached:
            Sys.println("Debugged process has detached.");

        case Files(list):
            printStringList(list, "\n");
            Sys.println("");

        case AllClasses(list):
            printStringList(list, "\n");
            Sys.println("");

        case Classes(list):
            // The command line controller never issues a request that should
            // have a Classes response, instead it asks for AllClasses
            throw "Internal error: unexpected Classes";

        case MemBytes(bytes):
            Sys.println(bytes + " bytes used.");

        case Compacted(bytesBefore, bytesAfter):
            Sys.println(bytesBefore + " bytes used before compaction.");
            Sys.println(bytesAfter + " bytes used after compaction.");

        case Collected(bytesBefore, bytesAfter):
            Sys.println(bytesBefore + " bytes used before collection.");
            Sys.println(bytesAfter + " bytes used after collection.");

        case ThreadLocation(number, frameNumber, className, functionName,
                            fileName, lineNumber, columnNumber):
            Sys.println("*     " + frameNumber + " : " +
                        className + "." + functionName + "() at " +
                        fileName + ":" + lineNumber + ": " + columnNumber);

        case FileLineBreakpointNumber(number):
            Sys.println("Breakpoint " + number + " set and enabled.");

        case ClassFunctionBreakpointNumber(number, unresolvableClasses):
            Sys.println("Breakpoint " + number + " set and enabled.");
            printUnresolvableClasses(unresolvableClasses);

        case Breakpoints(Terminator):
            Sys.println("No breakpoints.");

        case Breakpoints(list):
            Sys.println("Number | E/d | M | Description");
            while (true) {
                switch (list) {
                case Terminator:
                    break;
                case Breakpoint(number, description, enabled, multi, next):
                    Sys.println(padString(Std.string(number), 9) +
                                (enabled ? "E     " : "  d   ") +
                                (multi ? "*   " : "    ") + description);
                    list = next;
                }
            }

        case BreakpointDescription(number, Terminator):
            Sys.println("Breakpoint " + number + ":");
            Sys.println("    Breaks nowhere!");

        case BreakpointDescription(number, list):
            Sys.println("Breakpoint " + number + ":");
            while (true) {
                switch (list) {
                case Terminator:
                    break;
                case FileLine(fileName, lineNumber, columnNumber, next):
                    Sys.println("    Breaks at " + fileName + ":" +
                                lineNumber + ".");
                    list = next;
                case ClassFunction(className, functionName, next):
                    Sys.println("    Breaks at " + className + "." +
                                functionName + "().");
                    list = next;
                }
            }

        case BreakpointStatuses(Terminator):
            Sys.println("No breakpoints affected.");

        case BreakpointStatuses(list):
            while (true) {
                switch (list) {
                case Terminator:
                    break;
                case Nonexistent(number, next):
                    Sys.println("Breakpoint " + number + " does not exist.");
                    list = next;
                case Disabled(number, next):
                    Sys.println("Breakpoint " + number + " disabled.");
                    list = next;
                case AlreadyDisabled(number, next):
                    Sys.println("Breakpoint " + number +
                                " was already disabled.");
                    list = next;
                case Enabled(number, next):
                    Sys.println("Breakpoint " + number + " enabled.");
                    list = next;
                case AlreadyEnabled(number, next):
                    Sys.println("Breakpoint " + number +
                                " was already enabled.");
                    list = next;
                case Deleted(number, next):
                    Sys.println("Breakpoint " + number + " deleted.");
                    list = next;
                }
            }

        case ThreadsWhere(Terminator):
            Sys.println("No threads.");

        case ThreadsWhere(list):
            var needNewline : Bool = false;
            while (true) {
                switch (list) {
                case Terminator:
                    break;
                case Where(number, status, frameList, next):
                    if (needNewline) {
                        Sys.println("");
                    }
                    else {
                        needNewline = true;
                    }
                    Sys.print("Thread " + number + " (");
                    var isRunning : Bool = false;
                    switch (status) {
                    case Running:
                        Sys.println("running)");
                        list = next;
                        isRunning = true;
                    case StoppedImmediate:
                        Sys.println("stopped):");
                    case StoppedBreakpoint(number):
                        Sys.println("stopped in breakpoint " + number + "):");
                    case StoppedUncaughtException:
                        Sys.println("uncaught exception):");
                    case StoppedCriticalError(description):
                        Sys.println("critical error: " + description + "):");
                    }
                    var hasStack = false;
                    while (true) {
                        switch (frameList) {
                        case Terminator:
                            break;
                        case Frame(isCurrent, number, className, functionName,
                                   fileName, lineNumber, columnNumber, next):
                            Sys.print((isCurrent ? "* " : "  "));
                            Sys.print(padStringRight(Std.string(number), 5));
                            Sys.print(" : " + className + "." + functionName +
                                      "()");
                            Sys.println(" at " + fileName + ":" + lineNumber);
                            hasStack = true;
                            frameList = next;
                        }
                    }
                    if (!hasStack && !isRunning) {
                        Sys.println("No stack.");
                    }
                    list = next;
                }
            }

        case Variables(list):
            printStringList(list, "\n");
            Sys.println("");

        case Value(expression, type, value):
            Sys.println(expression + " : " + type + " = " + value);

        case Structured(structuredValue):
            throw "Internal error: unexpected Structured";

        case ThreadCreated(number):
            Sys.println("\nThread " + number + " created.");

        case ThreadTerminated(number):
            Sys.println("\nThread " + number + " terminated.");

        case ThreadStarted(number):
            // Don't print anything

        case ThreadStopped(number, frameNumber, className, functionName,
                           fileName, lineNumber, columnNumber):
            Sys.println("\nThread " + number + " stopped in " +
                        className + "." + functionName + "() at " +
                        fileName + ":" + lineNumber + ":" + columnNumber + ".");
        }
    }

    private function exit(regex : EReg) : Null<Command>
    {
        Sys.println("Exiting.");
        Sys.exit(0);
        return null;
    }

    private function detach(regex : EReg) : Null<Command>
    {
        return Detach;
    }

    private function help(regex : EReg)
    {
        if (regex.matched(1).length == 0) {
            Sys.println("For help on one of the following commands, use " +
                        "\"help <command>\".");
            Sys.println("For example, \"help break\":\n");
            for (h in gHelp) {
                Sys.println(padString(h.c, 10) + " : " + h.s);
            }
        }
        else {
            var cmd = regex.matched(1);
            for (h in gHelp) {
                if (h.c == cmd) {
                    Sys.println( h.l + "\n");
                    return null;
                }
            }

            Sys.println("No such command '" + cmd + "'");
        }
        return null;
    }

    private function source(regex : EReg) : Null<Command>
    {
        var line = regex.matched(1);
        if (line.length == 0) {
            Sys.println("The source command requires one argument.");
            return null;
        }
        if (gRegexQuotes.match(line)) {
            source_file(gRegexQuotes.matched(1));
        }
        else if (gRegexNoQuotes.match(line)) {
            source_file(gRegexNoQuotes.matched(1));
        }
        else {
            Sys.println("Failed to parse source line at: " + line + ".");
        }

        return null;
    }

    private function source_file(path : String) : Null<Command>
    {
        try {
            mInputs.push(sys.io.File.read(path));
            Sys.println("Executing debugger commands from " + path + " ...");
        }
        catch (e : Dynamic) {
            Sys.println("Failed to open " + path + " for sourcing.");
        }

        return null;
    }

    private function history(regex : EReg) : Null<Command>
    {
        this.historyRange(1, mStoredCommands.length - 1);
        return null;
    }

    private function history_at(regex : EReg) : Null<Command>
    {
        var number = Std.parseInt(regex.matched(1));
        this.historyRange(number, number);
        return null;
    }

    private function history_upto(regex : EReg) : Null<Command>
    {
        this.historyRange(1, Std.parseInt(regex.matched(1)));
        return null;
    }

    private function history_from(regex : EReg) : Null<Command>
    {
        this.historyRange(Std.parseInt(regex.matched(1)),
                           mStoredCommands.length - 1);
        return null;
    }

    private function history_from_upto(regex : EReg) : Null<Command>
    {
        this.historyRange(Std.parseInt(regex.matched(1)),
                          Std.parseInt(regex.matched(2)));
        return null;
    }

    private function historyRange(first : Int, last : Int)
    {
        if (first < 1) {
            first = 1;
        }

        if (last >= mStoredCommands.length) {
            last = (mStoredCommands.length - 1);
        }

        for (i in first ... (last + 1)) {
            Sys.println("(" + i + ") " + mStoredCommands[i]);
        }
    }

    private function files(regex : EReg) : Null<Command>
    {
        return Files;
    }

    private function filespath(regex : EReg) : Null<Command>
    {
        return FilesFullPath;
    }

    private function classes(regex : EReg) : Null<Command>
    {
        return AllClasses;
    }

    private function mem(regex : EReg) : Null<Command>
    {
        return Mem;
    }

    private function compact(regex : EReg) : Null<Command>
    {
        return Compact;
    }

    private function collect(regex : EReg) : Null<Command>
    {
        return Collect;
    }

    private function set_current_thread(regex : EReg) : Null<Command>
    {
        return SetCurrentThread(Std.parseInt(regex.matched(1)));
    }

    private function unsafe(regex : EReg) : Null<Command>
    {
        if (mUnsafeMode) {
            Sys.println("Already in unsafe mode.");
        }
        else {
            mUnsafeMode = true;
            Sys.println("Now in unsafe mode.");
        }

        return null;
    }

    private function safe(regex : EReg) : Null<Command>
    {
        if (mUnsafeMode) {
            mUnsafeMode = false;
            Sys.println("Now in safe mode.");
        }
        else {
            Sys.println("Already in safe mode.");
        }

        return null;
    }

    private function break_now(regex : EReg) : Null<Command>
    {
        return BreakNow;
    }
    //CS116 - changed 0 to 1
    private function break_file_line_col(regex : EReg) : Null<Command>
    {
        return AddFileLineBreakpoint(regex.matched(2),
                                     Std.parseInt(regex.matched(3)), Std.parseInt(regex.matched(4)));
    }

    private function break_file_line(regex : EReg) : Null<Command>
    {
        return AddFileLineBreakpoint(regex.matched(2),
                                     Std.parseInt(regex.matched(3)), -1);
    }

    private function break_class_function(regex : EReg) : Null<Command>
    {
        var full = regex.matched(2);
        var lastDot = full.lastIndexOf(".");
        return AddClassFunctionBreakpoint(full.substring(0, lastDot),
                                          full.substring(lastDot + 1));
    }

    private function break_class_regexp(regex : EReg) : Null<Command>
    {
        var full = regex.matched(2);
        var index = full.indexOf("/");
        var className = full.substring(0, index - 1);

        var value = full.substring(index);

        // Value starts with / ... look for end /
        index = findSlash(value, 1);

        if (index == -1) {
            Sys.println("Invalid command./641");
            return null;
        }

        return AddClassFunctionBreakpoint
            (className, value.substr(0, index + 1));
    }

    private function break_possible_regexps(regex : EReg) : Null<Command>
    {
        var value = regex.matched(2);

        // Value starts with / ... look for end /
        var index = findSlash(value, 1);

        if (index == -1) {
            Sys.println("Invalid command./657");
            return null;
        }

        var className = value.substr(0, index + 1);

        value = value.substr(index + 1);

        var regex = ~/[\s]*\.[\s]*([a-zA-Z_][a-zA-Z0-9_]*)[\s]*$/;
        if (regex.match(value)) {
            return AddClassFunctionBreakpoint(className, regex.matched(1));
        }

        regex = ~/[\s]*\.[\s]*(\/.*)$/;
        if (regex.match(value)) {
            value = regex.matched(1);

            // Value starts with / ... look for end /
            var index = findSlash(value, 1);

            if (index == -1) {
                Sys.println("Invalid command./678");
                return null;
            }

            return AddClassFunctionBreakpoint
                (className, value.substr(0, index + 1));
        }
        else {
            Sys.println("Invalid command./686");
            return null;
        }
    }

    private function list_all_breakpoints(regex : EReg) : Null<Command>
    {
        return ListBreakpoints(true, true);
    }

    private function list_enabled_breakpoints(regex : EReg) : Null<Command>
    {
        return ListBreakpoints(true, false);
    }

    private function list_disabled_breakpoints(regex : EReg) : Null<Command>
    {
        return ListBreakpoints(false, true);
    }

    private function describe_breakpoint(regex : EReg) : Null<Command>
    {
        return DescribeBreakpoint(Std.parseInt(regex.matched(2)));
    }

    private function disable_all_breakpoints(regex : EReg) : Null<Command>
    {
        return DisableAllBreakpoints;
    }

    private function disable_breakpoint(regex : EReg) : Null<Command>
    {
        var number = Std.parseInt(regex.matched(2));
        return DisableBreakpointRange(number, number);
    }

    private function disable_ranged_breakpoints(regex : EReg) : Null<Command>
    {
        return DisableBreakpointRange(Std.parseInt(regex.matched(2)),
                                      Std.parseInt(regex.matched(3)));
    }

    private function enable_all_breakpoints(regex : EReg) : Null<Command>
    {
        return EnableAllBreakpoints;
    }

    private function enable_breakpoint(regex : EReg) : Null<Command>
    {
        var number = Std.parseInt(regex.matched(2));
        return EnableBreakpointRange(number, number);
    }

    private function enable_ranged_breakpoints(regex : EReg) : Null<Command>
    {
        return EnableBreakpointRange(Std.parseInt(regex.matched(2)),
                                     Std.parseInt(regex.matched(3)));
    }

    private function delete_all_breakpoints(regex : EReg) : Null<Command>
    {
        return DeleteAllBreakpoints;
    }

    private function delete_breakpoint(regex : EReg) : Null<Command>
    {
        var number = Std.parseInt(regex.matched(2));
        return DeleteBreakpointRange(number, number);
    }

    private function delete_ranged_breakpoints(regex : EReg) : Null<Command>
    {
        return DeleteBreakpointRange(Std.parseInt(regex.matched(2)),
                                     Std.parseInt(regex.matched(3)));
    }

    private function clear_file_line(regex : EReg) : Null<Command>
    {
        return DeleteFileLineBreakpoint(regex.matched(1),
                                        Std.parseInt(regex.matched(2)), 0);
    }

    private function continue_current(regex : EReg) : Null<Command>
    {
        if (regex.matched(2).length > 0) {
            return Continue(Std.parseInt(regex.matched(2)));
        }
        else {
            return Continue(1);
        }
    }

    private function step_execution(regex : EReg) : Null<Command>
    {
        return Step((regex.matched(2).length > 0) ?
                    Std.parseInt(regex.matched(2)) : 1);
    }

    private function next_execution(regex : EReg) : Null<Command>
    {
        return Next((regex.matched(2).length > 0) ?
                    Std.parseInt(regex.matched(2)) : 1);
    }

    private function finish_execution(regex : EReg) : Null<Command>
    {
        return Finish((regex.matched(2).length > 0) ?
                      Std.parseInt(regex.matched(2)) : 1);
    }

    private function where(regex : EReg) : Null<Command>
    {
        return WhereCurrentThread(mUnsafeMode);
    }

    private function where_all(regex : EReg) : Null<Command>
    {
        return WhereAllThreads;
    }

    private function up_one(regex : EReg) : Null<Command>
    {
        return Up(1);
    }

    private function up_count(regex : EReg) : Null<Command>
    {
        return Up((regex.matched(1).length > 0) ?
                  Std.parseInt(regex.matched(1)) : 1);
    }

    private function down_one(regex : EReg) : Null<Command>
    {
        return Down(1);
    }

    private function down_count(regex : EReg) : Null<Command>
    {
        return Down((regex.matched(1).length > 0) ?
                    Std.parseInt(regex.matched(1)) : 1);
    }

    private function frame(regex : EReg) : Null<Command>
    {
        return SetFrame(Std.parseInt(regex.matched(1)));
    }

    private function variables(regex : EReg) : Null<Command>
    {
        return Variables(mUnsafeMode);
    }

    private function print_expression(regex : EReg) : Null<Command>
    {
        return PrintExpression(mUnsafeMode, regex.matched(2));
    }

    private function set_expression(regex : EReg) : Null<Command>
    {
        var expr = regex.matched(2);

        // Find the =
        var index = levelNextIndexOf(expr, 0, "=");
        if (index == -1){
            Sys.println("Expected = in set command.\n");
            return null;
        }

        return SetExpression(mUnsafeMode, expr.substr(0, index),
                             expr.substr(index + 1));
    }

    // Utility functions and helpers -----------------------------------------

    private static function printStringList(list : StringList, sep : String)
    {
        var need_sep = false;

        while (true) {
            switch (list) {
            case Terminator:
                break;
            case Element(string, next):
                if (need_sep) {
                    Sys.print(sep);
                }
                else {
                    need_sep = true;
                }
                Sys.print(string);
                list = next;
            }
        }
    }

    private static function printUnresolvableClasses(
                                              unresolvableClasses : StringList)
    {
        switch (unresolvableClasses) {
        case Terminator:
        case Element(string, next):
            Sys.print("Unresolvable classes: ");
            printStringList(unresolvableClasses, ", ");
            Sys.println(".");
        }
    }

    private static function findEndQuote(str : String, index : Int) : Int
    {
        while (index < str.length) {
            var quoteIndex = str.indexOf("\"", index);
            // Count backslashes before quotes
            var slashCount = 0;
            var si : Int = quoteIndex - 1;
            while ((si >= 0) && (str.charAt(si) == "\\")) {
                slashCount += 1;
                si -= 1;
            }
            // If there are an even number of slashes, then the quote
            // is not escaped
            if ((slashCount % 2) == 0) {
                return quoteIndex;
            }
            // Else the quote is escaped
            else {
                index = quoteIndex + 1;
            }
        }
        return -1;
    }

    private static function levelNextIndexOf(str : String, index : Int,
                                             find : String) : Int
    {
        var bracketLevel = 0, parenLevel = 0;

        while (index < str.length) {
            var char = str.charAt(index);
            if ((char == find) && (bracketLevel == 0) && (parenLevel == 0)) {
                return index;
            }
            else if (char == "[") {
                bracketLevel += 1;
            }
            else if (char == "]") {
                bracketLevel -= 1;
            }
            else if (char == "(") {
                parenLevel += 1;
            }
            else if (char == ")") {
                parenLevel -= 1;
            }
            else if (char == "\"") {
                var endQuote = findEndQuote(str, index + 1);
                if (endQuote == -1) {
                    throw "Mismatched quotes";
                }
                index = endQuote;
            }
            index += 1;
        }

        return -1;
    }

    private static function findSlash(str : String, index : Int) : Int
    {
        while (index < str.length) {
            var char = str.charAt(index);
            if ((char == "/") &&
                ((index == 0) || (str.charAt(index - 1) != "\\"))) {
                return index;
            }
            index += 1;
        }
        return -1;
    }

    private static function padString(str : String, width : Int)
    {
        var spacesNeeded = width - str.length;

        if (spacesNeeded <= 0) {
            return str;
        }

        if (gEmptySpace[spacesNeeded] == null) {
            var str = "";
            for (i in 0...spacesNeeded) {
                str += " ";
            }
            gEmptySpace[spacesNeeded] = str;
        }

        return (str + gEmptySpace[spacesNeeded]);
    }

    private static function padStringRight(str : String, width : Int)
    {
        var spacesNeeded = width - str.length;

        if (spacesNeeded <= 0) {
            return str;
        }

        if (gEmptySpace[spacesNeeded] == null) {
            var str = "";
            for (i in 0...spacesNeeded) {
                str += " ";
            }
            gEmptySpace[spacesNeeded] = str;
        }

        return (gEmptySpace[spacesNeeded] + str);
    }

    private function setupRegexHandlers()
    {
        mRegexHandlers = [
  { r: ~/^(quit|exit)[\s]*$/, h: exit },
  { r: ~/^detach[\s]*$/, h: detach },
  { r: ~/^help()[\s]*$/, h: help },
  { r: ~/^help[\s]+([^\s]*)$/, h: help },
  { r: ~/^source[\s]+(.*)$/, h: source },
  { r: ~/^history[\s]*$/, h: history },
  { r: ~/^history[\s]+([0-9]+)$/, h: history_at },
  { r: ~/^history[\s]+-[\s]*([0-9]+)$/, h: history_upto },
  { r: ~/^history[\s]+([0-9]+)[\s]*-$/, h: history_from },
  { r: ~/^history[\s]+([0-9]+)[\s]*-[\s]*([0-9]+)$/, h: history_from_upto },
  { r: ~/^filespath[\s]*$/, h: filespath },
  { r: ~/^files[\s]*$/, h: files },
  { r: ~/^classes[\s]*$/, h: classes },
  { r: ~/^mem[\s]*$/, h: mem },
  { r: ~/^compact[\s]*$/, h: compact },
  { r: ~/^collect[\s]*$/, h: collect },
  { r: ~/^thread[\s]+([0-9]+)[\s]*$/, h: set_current_thread },
  { r: ~/^unsafe[\s]*$/, h: unsafe },
  { r: ~/^safe[\s]*$/, h: safe },
  { r: ~/^(b|break)[\s]*$/, h : break_now },
  { r: ~/^(b|break)[\s]+([^:]+):[\s]*([0-9]+):[\s]*([0-9]+)[\s]*$/, h : break_file_line_col },
  { r: ~/^(b|break)[\s]+([^:]+):[\s]*([0-9]+)[\s]*$/, h : break_file_line },
  { r: ~/^(b|break)[\s]+(([a-zA-Z0-9_]+\.)+[a-zA-Z0-9_]+)[\s]*$/, h : break_class_function },
  { r: ~/^(b|break)[\s]+(([a-zA-Z0-9_]+\.)+\/.*)$/, h : break_class_regexp },
  { r: ~/^(b|break)[\s]+(\/.*)$/, h : break_possible_regexps },
  { r: ~/^lb[\s]*$/, h : list_all_breakpoints },
  { r: ~/^(l|list)[\s]+(all[\s]+)?(b|breakpoints)$/, h : list_all_breakpoints },
  { r: ~/^(l|list)[\s]+(en|enabled)[\s]+(b|breakpoints)$/,
    h : list_enabled_breakpoints },
  { r: ~/^(l|list)[\s]+(dis|disabled)[\s]+(b|breakpoints)$/,
    h : list_disabled_breakpoints },
  { r: ~/^(desc|describe)[\s]+([0-9]+)[\s]*$/, h: describe_breakpoint },
  { r: ~/^(dis|disable)[\s]+all[\s]*$/, h: disable_all_breakpoints },
  { r: ~/^(dis|disable)[\s]+([0-9]+)[\s]*$/, h: disable_breakpoint },
  { r: ~/^(dis|disable)[\s]+([0-9]+)[\s]*-[\s]*([0-9]+)[\s]*$/,
    h: disable_ranged_breakpoints },
  { r: ~/^(en|enable)[\s]+all[\s]*$/, h: enable_all_breakpoints },
  { r: ~/^(en|enable)[\s]+([0-9]+)[\s]*$/, h: enable_breakpoint },
  { r: ~/^(en|enable)[\s]+([0-9]+)[\s]*-[\s]*([0-9]+)[\s]*$/,
    h: enable_ranged_breakpoints },
  { r: ~/^(d|delete)[\s]+all[\s]*$/, h: delete_all_breakpoints },
  { r: ~/^(d|delete)[\s]+([0-9]+)[\s]*$/, h: delete_breakpoint },
  { r: ~/^(d|delete)[\s]+([0-9]+)[\s]*-[\s]*([0-9]+)[\s]*$/,
    h: delete_ranged_breakpoints },
  { r: ~/^clear[\s]+([^:]+):[\s]*([0-9]+)[\s]*$/, h : clear_file_line },
  { r: ~/^(continue|cont|c)()[\s]*$/, h: continue_current },
  { r: ~/^(continue|cont|c)([\s]+[0-9]+)[\s]*$/,h: continue_current },
  { r: ~/^(step|stepi|s)()[\s]*$/, h: step_execution },
  { r: ~/^(step|stepi|s)([\s]+[0-9]+)[\s]*$/, h: step_execution },
  { r: ~/^(next|nexti|n)()[\s]*$/, h: next_execution },
  { r: ~/^(next|nexti|n)([\s]+[0-9]+)[\s]*$/, h: next_execution },
  { r: ~/^(finish|f)()[\s]*$/, h: finish_execution },
  { r: ~/^(finish|f)([\s]+[0-9]+)[\s]*$/, h: finish_execution },
  { r: ~/^(where|w)[\s]*$/, h: where },
  { r: ~/^(where|w)[\s]+all[\s]*$/, h: where_all },
  { r: ~/^up[\s]*$/, h: up_one },
  { r: ~/^up[\s]+([0-9]+)[\s]*$/, h: up_count },
  { r: ~/^down[\s]*$/, h: down_one },
  { r: ~/^down[\s]+([0-9]+)[\s]*$/, h: down_count },
  { r: ~/^frame[\s]+([0-9]+)[\s]*$/, h: frame },
  { r: ~/^(vars|variables)[\s]*$/, h : variables },
  { r: ~/^(p|print)[\s]+(.*)$/, h: print_expression },
  { r: ~/^(s|set)[\s]+(.*)$/, h: set_expression }
                          ];
    }

    private var mUnsafeMode : Bool;
    private var mInputs : Array<haxe.io.Input>;
    private var mStoredCommands : Array<String>;
    private var mLastCommand : Command;
    private var mRegexHandlers : Array<RegexHandler>;
    private static var gRegexQuotes = ~/^[\s]*"([^"]+)"[\s]*$/;
    private static var gRegexNoQuotes = ~/^[\s]*([^\s"]+)[\s]*$/;
    private static var gEmptySpace : Array<String> = [ "" ];
    private static var gHelp : Array<Help> =
        [
         { c : "input",     s : "Inputting and repeating commands",
 l : "Every comand prompt is preceded by a number.  When a command is\n" +
     "entered, it may be repeated later with the command \"!N\", where N is\n" +
     "that number.  For example:\n\n" +
     "   4> mem\n\n" +
     "   844323 bytes used.\n\n" +
     "   5> !4\n\n" +
     "   844323 bytes used.\n\n" +
     "The history of commands that can be repeated is printed by the\n" +
     "'history' command.\n\n" +
     "Some commands are repeated if an empty line is read immediately after\n" +
     "the command.  The commands which repeat are: continue, step, next,\n" +
     "finish, up, and down.  Commands are only repeated when commands are\n" +
     "being read from the user (not when sourcing files).\n\n" +
     "If at any time an asynchronous threading message interrupts a command\n" +
     "being typed in, ending the command with '\\' will re-print the\n" +
     "current command prompt and command in progress.  For example:\n\n" +
     "   8> b Foo.h\n" +
     "   Thread 4 terminated.\n" +
     "   \\\n" +
     "   8> b Foo.hx:10\n\n" +
     "Here, the user was in the middie of typing a 'b' command when a\n" +
     "thread terminated.  The user entered a bare '\\' to cause the command\n" +
     "in progress to be re-printed so that the user could see the command\n" +
     "being typed in and then complete it." },

         { c : "quit",      s : "Quits the debugger",
 l : "Syntax: quit/exit\n\n" +
     "The quit (or exit) command exits the debugger and the debugged " +
     "process." },

         { c : "detach",    s : "Detaches the debugger",
 l : "Syntax: detach\n\n" +
     "The detach command detaches the debugger from the debugged process.\n" +
     "The debugger exits but the debugged process continues to execute." },

         { c : "help",      s : "Displays command help",
 l : "Syntax: help [command]\n\n" +
     "With no arguments, the help command prints out a list of all\n" +
     "commands.  With an argument, the help command prints out detailed\n" +
     "help about that command." },

         { c : "source",    s : "Runs commands from a file",
 l : "Syntax: source <filename>\n\n" +
     "The source command reads in and executes commands from the file\n" +
     "<filename> as if they had been typed in at the command prompt.\n" +
     "Comment lines beginning with '#' in the input file are ignored.\n" +
     "After execution of all commands from the file, input resumes at the\n" +
     "normal interactive prompt." },

         { c : "history",   s : "Displays command history",
 l : "Syntax: history/h <N>/<N>-/<M>-<M>/-<M>\n\n" +
     "The history (or h) command displays the list of commands previously\n" +
     "entered either at the command prompt or when sourcing a file.\n" +
     "Several variations are supported for specifying the extent of\n" +
     "command history to display:\n\n" +
     "  history          : Displays all history.\n" +
     "  history <N>      : Displays the history of command N.\n" +
     "  history <N>-     : Displays history of all commands starting with " +
     "N.\n" +
     "  history <N>-<M>  : Displays history in the range N - M, inclusive.\n" +
     "  history -<M>     : Displays history of in the range 1 - M, " +
     "inclusive." },

         { c : "files",     s : "Lists debuggable files",
 l : "Syntax: files\n\n" +
     "The files command lists all files in which file:line breakpoints may\n" +
     "be set." },

         { c : "filespath",     s : "Lists full paths of the debuggable files",
 l : "Syntax: files\n\n" +
     "The order of theses paths matches the order of the 'files' command.\n" +
     "Use this to work out which file to edit." },


         { c : "classes",   s : "Lists debuggable classes",
 l : "Syntax: classes\n\n" +
     "The classes command lists all classes in which class:function\n" +
     "breakpoints may be set.  This is all classes known to the compiler\n" +
     "at the time the debugged program was compiled." },

         { c : "mem",       s : "Displays memory usage",
 l : "Syntax: mem\n\n" +
     "The mem command displays the amount of bytes currently used by the\n" +
     "debugged process." },

         { c : "compact",   s : "Compacts the heap",
 l : "Syntax: compact\n\n" +
     "The compact command compacts the program's heap as much as possible\n" +
     "and prints out the number of bytes used by the program before and\n" +
     "after compaction." },

         { c : "collect",   s : "Runs the garbage collector",
 l : "Syntax: compact\n\n" +
     "The compact command compacts the program's heap as much as possible\n" +
     "and prints out the number of bytes used by the program before and\n" +
     "after compaction." },

         { c : "thread",    s : "Sets the current thread",
 l : "Syntax: thread <number>\n\n" +
     "The thread command switches the debugger to thread <number>, making\n" +
     "this thread the current thread.  The current thread is the thread\n" +
     "which is targeted by the following commands:\n\n" +
     "  continue, step, next, finish, where, up, down, frame, print, set" },

         { c : "unsafe",    s : "Puts the debugger into unsafe mode",
 l : "Syntax: unsafe\n\n" +
     "The unsafe command puts the debugger into unsafe mode.  In unsafe\n" +
     "mode, the debugger will print stack traces and allow the printing\n" +
     "and setting of stack variables for threads which are not stopped.\n" +
     "this is extremely unsafe and could lead to program crashes or other\n" +
     "undefined behavior as threads which are actively running are\n" +
     "manipulated in unsafe mode.  However, if a thread is hung and cannot\n" +
     "be induced to break at a breakpoint, unsafe mode can allow the\n" +
     "inspection of the thread's state to determine what the cause of the\n" +
     "hang could be.  To leave unsafe mode, use the 'safe' command." },

         { c : "safe",      s : "Puts the debugger into safe mode",
 l : "Syntax: safe\n\n" +
     "The safe command puts the debugger back into safe mode from unsafe\n" +
     "mode.  In safe mode, the call stack of only stopped threads can be\n" +
     "examined and call stack variables of only stopped threads can be\n" +
     "printed or modified.  To leave safe mode, use the 'unsafe' command." },

         { c : "break",     s : "Sets a breakpoint",
 l : "Syntax: break <file>:<line>/<class>.<function>\n\n" +
     "The break (or b) command sets a breakpoint.  Breakpoints take effect\n" +
     "immediately and all threads will break on all breakpoints whenever\n" +
     "the breakpoint is hit.\n" +
     "Breakpoints may be specified either by file and line number, or by\n" +
     "class name and function name.\n" +
     "In the class.function case, the class name, or function name or\n" +
     "both, may optionally be a regular expression which will cause the\n" +
     "breakpoint to break on all matching functions.\n" +
     "The set of files in which breakpoints may be set can be printed using\n" +
     "the 'files' command.  The set of classes in which breakpoints may\n" +
     "be set can be printed using the 'classes' command.\n\nExamples:\n\n" +
     "  b Foo.hx:10\n" +
     "      Sets a breakpoint in file Foo.hx line 10.\n\n" +
     "  b SomeClass.SomeFunction\n " +
     "      Sets a breakpoint on entry to the function " +
     "SomeClass.SomeFunction.\n\n" +
     "  b SomeClass./get.*/\n" +
     "      Sets a breakpoint on entry to all functions whose names begin\n" +
     "      with 'get' in the class SomeClass.\n\n" +
     "  b /.*/.new\n" +
     "      Sets a breakpoint on entry to the constructor of every class.\n\n" +
     "  b /.*/./.*/\n" +
     "      Sets a breakpoint on entry to every function of every class." },

         { c : "list",     s : "Lists breakpoints",
 l : "Syntax: list/l [all/enabled/en/disabled/dis] breakpoints/b\n\n" +
     "The list (or l) command lists all breakpoints that match the given\n" +
     "criteria.  The criteria default to 'all' if not specified, and may be\n" +
     "specified as one of:\n\n" +
     "  all                : to list all breakpoints\n" +
     "  enabled (or en)    : to list only enabled breakpoints\n" +
     "  disabled (or dis)  : to list only disabled breakpoints\n\n" +
     "Note that the syntax of the command requires the word 'breakpoints'\n" +
     "(or b) at the end.  Examples:\n\n" +
     "  list all breakpoints\n" +
     "      Lists all breakpoints\n\n" +
     "  l en breakpoints\n" +
     "      Lists only enabled breakpoints\n\n" +
     "  l dis b\n" +
     "      Lists only disabled breakpoints\n\n" +
     "The breakpoints are listed with the following columns:\n\n" +
     "  Number       : The breakpoint number.\n" +
     "  E/d          : Enabled or disabled.  A value of E means that the\n" +
     "                 breakpoint is enabled, d means that the breakpoint " +
     "is\n" +
     "                 disabled.\n" +
     "  M            : Indicates whether or not the breakpoint breaks in\n" +
     "                 multiple code locations, which can be true for\n" +
     "                 regex-specified breakpoints.  The 'describe' command\n" +
     "                 is useful for listing the multiple code locations\n" +
     "                 of a regex-specified Multi breakpoint.\n" +
     "  Description  : Describes the breakpoint." },

         { c : "describe",  s : "Describes a breakpoint",
 l : "Syntax: describe/desc <breakpoint>\n\n" +
     "The describe (or desc) command lists the code locations at which\n" +
     "a breakpoint will break.  This is especially useful for breakpoints\n" +
     "which were specified using regexps that matched more than one class\n" +
     "and/or function." },

         { c : "disable",   s : "Disables breakpoints",
 l : "Syntax: disable/dis all/<N>/<N>-<M>\n\n" +
     "The disable (or dis) command disables a set of breakpoints.\n" +
     "Several variations are supported for specifying the range of\n" +
     "breakpoints to disable:\n\n" +
     "  disable all      : Disables all breakpoints.\n" +
     "  disable <N>      : Disables breakpoint N.\n" +
     "  disable <N>-<M>  : Disables breakpoints in the range N - M, " +
     "inclusive.\n" },

         { c : "enable",    s : "Enables breakpoints",
 l : "Syntax: enable/en all/<N>/<N>-<M>\n\n" +
     "The enable (or en) command enables a set of breakpoints.\n" +
     "Several variations are supported for specifying the range of\n" +
     "breakpoints to enable:\n\n" +
     "  enable all       : Enables all breakpoints.\n" +
     "  enable <N>       : Enables breakpoint N.\n" +
     "  enable <N>-<M>   : Enables breakpoints in the range N - M, " +
     "inclusive.\n" },

         { c : "delete",    s : "Deletes breakpoints",
 l : "Syntax: delete/d all/<N>/<N>-<M>\n\n" +
     "The delete (or d) command deletes a set of breakpoints.\n" +
     "Several variations are supported for specifying the range of\n" +
     "breakpoints to delete:\n\n" +
     "  delete all       : Deletes all breakpoints.\n" +
     "  delete <N>       : Deletes breakpoint N.\n" +
     "  delete <N>-<M>   : Deletes breakpoints in the range N - M, " +
     "inclusive.\n" },

         { c : "clear",    s : "Deletes a breakpoint",
 l : "Syntax: clear <file>:<line>\n\n" +
     "The clear command deletes a single file:line breakpoint." },

         { c : "continue",  s : "Continues thread execution",
 l : "Syntax: continue/c <N>\n\n" +
     "The continue (or c) command continues threads until the\n" +
     "next breakpoint occurs.  An optional parameter N gives the number of\n" +
     "breakpoints past which to continue just for the current thread (all\n" +
     "other threads continue until the next breapoint).  If N is not\n" +
     "specified, it defaults to 1." },

         { c : "step",      s : "Single steps a thread",
 l : "Syntax: step/s [N]\n\n" +
     "The step (or s) command steps the current thread.  This causes the\n" +
     "current thread to execute the next line of Haxe code and to stop\n" +
     "immediately thereafter.  This could include entering a function and\n" +
     "executing the first line of code in that function.  The optional\n" +
     "parameter N specifies how many lines to step.  If not provided, the\n" +
     " default is 1." },

         { c : "next",      s : "Single steps a thread in current frame",
 l : "Syntax: next/n [N]\n\n" +
     "The next (or n) command steps the current thread over a function\n" +
     "call.  If the next line of Haxe code to execute is a function call,\n" +
     "the entire function is executed and the thread stops before\n" +
     "executing the line of code after the function call.  If the next line\n" +
     "of Haxe code is not a function, the next command behaves exactly like\n" +
     "the step command.  The optional parameter N specifies how many\n" +
     "function calls or Haxe lines of code to step.  If not provided, the\n" +
     " default is 1." },

         { c : "finish",    s : "Continues until return from frame",
 l : "Syntax: finish/f [N]\n\n" +
     "The finish (or f) command causes the current thread to finish\n" +
     "execution of the current function and stop before executing the next\n" +
     "line of code in the calling function.  The optional parameter N\n" +
     "specifies how many function calls to finish.  If not provided, the\n" +
     "default is 1." },

         { c : "where",     s : "Displays thread call stack",
 l : "Syntax: where/w [all]\n\n" +
     "The where (or w) command lists the call stack of a thread or threads,\n" +
     "as well as giving execution status of that thread or those threads.\n" +
     "The call stack is listed with the lowest stack frame (i.e. the one\n" +
     "currently being executed) first and the highest stack frame last,\n" +
     "and these frames are numbered in reverse order so that the numbers\n" +
     "do not change as stack frames are added.  The current stack frame\n" +
     "being examined is demarcated with an asterisk.   Two variations are\n" +
     "supported for specifying the threads to show call stack and status\n" +
     "of:\n\n" +
     "  where      : Shows stack frame and status for the current thread.\n" +
     "  where all  : Shows stack frame and status for all threads." },

         { c : "up",        s : "Moves up the call stack",
  l : "Syntax: up [N]\n\n" +
      "The up command moves the current stack frame being examined up a\n" +
      "number of frames.  The optional parameter N specifies how many\n" +
      "frames to move up.  The default if N is not provided is 1.  Note " +
      "that\n" +
      "moving up the call stack means moving to lower call frame numbers." },

         { c : "down",      s : "Moves down the call stack",
  l : "Syntax: down [N]\n\n" +
      "The down command moves the current stack frame being examined down a\n" +
      "number of frames.  The optional parameter N specifies how many\n" +
      "frames to move down.  The default if N is not provided is 1.  Note " +
      "that\n" +
      "moving down the call stack means moving to higher call frame numbers." },

         { c : "frame",     s : "Moves to a specific call stack frame",
  l : "Syntax: frame <N>\n\n" +
      "The frame command moves the current stack frame being examined to a\n" +
      "specific frame.  The parameter N specifies which frame to move to." },

         { c : "variables", s : "Prints available stack variables",
  l : "Syntax: variables/vars\n\n" +
      "The variables (or vars) command lists all stack variables present\n" +
      "in the current stack frame." },

         { c : "print",     s : "Prints values from debugged process",
  l : "Syntax: print/p <expression>\n\n" +
      "The print (or p) command evaluates and prints the results of Haxe " +
      "expressions.\n" +
      "This is typically used for examining variables on the stack or in\n" +
      "global scope, but can be used for the side effect of executing\n" +
      "Haxe function calls if desired.  The expressions that can be\n" +
      "evaluated and the results printed include all syntax necessary to\n" +
      "identify variable values, but does not include syntax for executing\n" +
      "arbitrary Haxe code.  For example, math operators are not supported.\n" +
      "Examples:\n\n" +
      "  print foo\n" +
      "      Prints the value of the variable 'foo' in the current scope.\n" +
      "      If foo is a variable on the stack, it is printed; otherwise,\n" +
      "      if foo is a member of the 'this' variable, then that is " +
      "printed.\n\n" +
      "  print someVariable.mArray[4]\n" +
      "      Prints the value of the 5th element of the 'mArray' array\n" +
      "      of the someVariable value.\n\n" +
      "  print someVariable.doSomething(7)\n" +
      "      Prints the result of calling the 'doSomething' function of\n" +
      "      'someVariable' instance, passing in 7 as the argument.\n\n" +
      "Note that class member variables and array member variables of\n" +
      "classes that are printed are ellipsed to prevent the output from\n" +
      "being too large.  To see the contents of these values, print them\n" +
      "via a print command targeting them." },

         { c : "set",       s : "Sets values in debugged process",
   l : "Syntax: set/s <expression> = <expression>\n\n" +
       "The set (or s) command evaluates a left hand side and a right hand\n" +
       "side Haxe expression and sets the value referenced by the left hand\n" +
       "side to the value identified by the right hand side.  The allowed\n" +
       "expression syntax is identical to that of the print command.\n\n" +
       "There is a special variable name '$', which can be used to store\n" +
       "arbitrary values in the debugger that can be printed later or used\n" +
       "in expressions.  An example of its use:\n\n" +
       "  4> set $.foo = 1\n\n" +
       "  $.foo : Int = 1\n\n" +
       "  5> set $.bar = \"Hello, world\"\n\n" +
       "  $.bar : String = \"Hello, world\"\n\n" +
       "  6> set $.baz = [ 1, 2, 3, 4 ]\n\n" +
       "  $.baz : Array<Int>[4] = [ 1, 2, 3, 4 ]\n\n" +
       "  7> p $.bar\n\n" +
       "  $.bar : String = \"Hello, world\"\n\n" +
       "  8> p $\n\n" +
       "  $ : Debugger variables = \n\n" +
       "  $.bar : String = \"Hello, world\"\n" +
       "  $.baz : Array<Int>[4] = [ 1, 2, 3, 4 ]\n" +
       "  $.foo : Int = 1\n\n" +
       "  9> set someValue.arr = $.baz\n\n" +
       "  someValue.arr : Array<Int>[4] = [ 1, 2, 3, 4 ]" }
         ];
}


private typedef RegexHandler =
{
    var r : EReg;
    var h : EReg -> Null<Command>;
}


private typedef Help =
{
    var c : String; // command
    var s : String; // short help
    var l : String; // long help
}
