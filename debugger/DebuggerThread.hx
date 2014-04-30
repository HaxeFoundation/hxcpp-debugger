/** **************************************************************************
 * DebuggerThread.hx
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

import cpp.vm.Debugger;
import debugger.IController;

#if cpp
import cpp.vm.Deque;
import cpp.vm.Mutex;
import cpp.vm.Thread;
#elseif neko
import neko.vm.Deque;
import neko.vm.Mutex;
import neko.vm.Thread;
#else
#error "DebuggerThread supported only for cpp and neko targets"
#end


/**
 * This class actually implements a debugger loop, which runs in a thread
 * and executes debugger commands.  There can only be one
 * DebuggerThread in a program at a time.  Its constructor spawns a
 * debugging thread that will read commands from its controller, execute them,
 * and provide messages describing the results and also describing spurious
 * thread events.
 **/
class DebuggerThread
{
    /**
     * Creates an DebuggerThread which will acquire commands from and
     * send messages to the given controller.
     *
     * @param controller is the controller from which commands will be read
     *        and to which messages will be written
     * @param startStopped if true, all threads except the debugger thread
     *        itself will be stopped when the debugger thread starts.  If
     *        false, the calling thread will continue to run after the
     *        debugging thread has been created.
     **/
    public function new(controller : IController, startStopped : Bool)
    {
#if !HXCPP_DEBUGGER
        Sys.println("Warning: This program was not compiled with the " +
                    "HXCPP_DEBUGGER flag set, debugging not supported.");
        return;
#end
        if (gStartMutex == null) {
            throw "Debug thread cannot be constructed by a static initializer";
        }

        // Ensure that there isn't a debugger already
        gStartMutex.acquire();
        if (gStarted) {
            gStartMutex.release();
            throw ("Debug thread constructor failed - there is already a " +
                   "debugger running");
        }
        gStarted = true;
        gStartMutex.release();

        // Set up instance state
        mStateMutex = new Mutex();
        mController = controller;
        mCurrentThreadNumber = Debugger.getCurrentThreadNumber();
        mCurrentThreadInfo = null;
        mBreakpoints = new haxe.ds.IntMap<Breakpoint>();
        mBreakpointsByDescription = new haxe.ds.StringMap<Breakpoint>();
        mNextBreakpointNumber = 1;
        mDebuggerVariables = new DebuggerVariables();

        // Set gStartStopped so that the debugger thread will know whether to
        // stop the program
        gStartStopped = startStopped;

        // Start the real debugger thread running.  Before doing so, ensure
        // that the current thread will not stop until this function is
        // exited.
        Debugger.enableCurrentThreadDebugging(false);

        Thread.create(debuggerThreadMain);

        if (startStopped) {
            // Cannot proceed until the debugger thread has notified us that
            // it's OK to proceed.
            gStartQueue.pop(true);
        }

        // Once this function is called, the current thread can break
        Debugger.enableCurrentThreadDebugging(true);
    }


    // ------------------------------------------------------------------------
    // ------------------------------------------------------------------------
    // Private implementation follows
    // ------------------------------------------------------------------------
    // ------------------------------------------------------------------------

    private function debuggerThreadMain()
    {
        // Set the thread event notification handler
        Debugger.setEventNotificationHandler(handleThreadEvent);

        // If the 'started debugger thread' is set, it means that debugging
        // was to start with all threads (aside from the debugger thread)
        // stopped, so do so now.
        if (gStartStopped) {
            // Ensure that the main thread will break once it gets past its
            // unbreakable region - but don't wait for it to break since it's
            // currently blocking on gStartQueue.
            Debugger.breakNow(false);
            // Signal to the started debugger thread to proceed (which will
            // cause it to immediately break at the instruction after its
            // readMessage() call in its constructor).
            gStartQueue.push(true);
            // This call does not return until all threads (except for the
            // calling thread) have been broken.
            Debugger.breakNow(true);
        }
        // Else, just let the main thread go now
        else {
            gStartQueue.push(true);
        }

        // Now run the main loop
        try {
            while (true) {
                switch (mController.getNextCommand()) {
                case Exit:
                    emit(Exited);
                    Sys.exit(0);

                case Detach:
                    emit(Detached);
                    return;

                case Files:
                    emit(this.files());

                case FilesFullPath:
                    emit(this.filesFullPath());

                case Classes:
                    emit(this.classes());

                case Mem:
                    emit(this.mem());

                case Compact:
                    emit(this.compact());

                case Collect:
                    emit(this.collect());

                case SetCurrentThread(number):
                    emit(this.setCurrentThread(number));

                case AddFileLineBreakpoint(fileName, lineNumber):
                    emit(this.addFileLineBreakpoint(fileName, lineNumber));

                case AddClassFunctionBreakpoint(className, functionName):
                    emit(this.addClassFunctionBreakpoint
                         (className, functionName));

                case ListBreakpoints(enabled, disabled):
                    emit(this.listBreakpoints(enabled, disabled));

                case DescribeBreakpoint(number):
                    emit(this.describeBreakpoint(number));

                case DisableAllBreakpoints:
                    emit(this.disableAllBreakpoints());

                case DisableBreakpointRange(first, last):
                    emit(this.disableBreakpointRange(first, last));

                case EnableAllBreakpoints:
                    emit(this.enableAllBreakpoints());

                case EnableBreakpointRange(first, last):
                    emit(this.enableBreakpointRange(first, last));

                case DeleteAllBreakpoints:
                    emit(this.deleteAllBreakpoints());

                case DeleteBreakpointRange(first, last):
                    emit(this.deleteBreakpointRange(first, last));

                case BreakNow:
                    emit(this.breakNow());

                case Continue(count):
                    emit(this.continueCurrent(count));

                case Step(count):
                    emit(this.step(count));

                case Next(count):
                    emit(this.next(count));

                case Finish(count):
                    emit(this.finish(count));

                case WhereCurrentThread(unsafe):
                    emit(this.whereCurrentThread(unsafe));

                case WhereAllThreads:
                    emit(this.whereAllThreads());

                case Up(count):
                    emit(this.up(count));

                case Down(count):
                    emit(this.down(count));

                case SetFrame(number):
                    emit(this.setFrame(number));

                case Variables(unsafe):
                    emit(this.variables(unsafe));

                case PrintExpression(unsafe, expression):
                    emit(this.printExpression(unsafe, expression));

                case SetExpression(unsafe, lhs, rhs):
                    emit(this.setExpression(unsafe, lhs, rhs));
                }
            }
        }
        catch (e : Dynamic) {
            emit(ErrorInternal("Exception in debugger, detaching: " + e));
        }

        // No longer want to know about thread events
        Debugger.setEventNotificationHandler(null);

        // Delete all breakpoints from the debugged process
        this.deleteAllBreakpoints();

        emit(Detached);

        // Ensure that all threads are running
        Debugger.continueThreads(-1, 1);

        // Another thread might immediately start another debugger and re-set
        // gStartedDebuggerThread, which is why it was latched previously.
        gStarted = false;
    }

    private function handleThreadEvent(threadNumber : Int, event : Int,
                                       stackFrame : Int,
                                       className : String,
                                       functionName : String,
                                       fileName : String, lineNumber : Int)
    {
        switch (event) {
        case Debugger.THREAD_CREATED:
            emit(ThreadCreated(threadNumber));
        case Debugger.THREAD_TERMINATED:
            mStateMutex.acquire();
            if (threadNumber == mCurrentThreadNumber) {
                mCurrentThreadInfo = null;
            }
            mStateMutex.release();
            emit(ThreadTerminated(threadNumber));
        case Debugger.THREAD_STARTED:
            mStateMutex.acquire();
            if (threadNumber == mCurrentThreadNumber) {
                mCurrentThreadInfo = null;
            }
            mStateMutex.release();
            emit(ThreadStarted(threadNumber));
        case Debugger.THREAD_STOPPED:
            mStateMutex.acquire();
            if (threadNumber == mCurrentThreadNumber) {
                mCurrentThreadInfo = null;
            }
            mStateMutex.release();
            emit(ThreadStopped(threadNumber, className, functionName,
                               fileName, lineNumber));
        }
    }

    private function emit(message : Message)
    {
        mController.acceptMessage(message);
    }

    private function filesToList(files:Array<String>) : StringList
    {
        var list : StringList = Terminator;

        // Preserve order
        for (f in 0...files.length) {
            list = Element(files[files.length-1-f], list);
        }

        return list;
    }

    private function files() : Message
    {
        // Preserve order to match filesFullPath
        return Files( filesToList( Debugger.getFiles() ) );
    }

    private function filesFullPath() : Message
    {
        return FilesFullPath( filesToList( Debugger.getFilesFullPath() ) );
    }


    private function classes() : Message
    {
        var classes = Debugger.getClasses();

        var list : StringList = Terminator;

        // Sort the classes in reverse so that the list can be created easily
        classes.sort(function (a : String, b : String) {
                return Reflect.compare(b, a);
            });

        for (f in classes) {
            list = Element(f, list);
        }

        return Classes(list);
    }

    private function mem() : Message
    {
#if cpp
        return MemBytes(cpp.vm.Gc.memUsage());
#else
        return MemBytes(neko.vm.Gc.stats().heap);
#end
    }

    private function compact() : Message
    {
#if cpp
        var pre = cpp.vm.Gc.memUsage();
        cpp.vm.Gc.compact();
        var post = cpp.vm.Gc.memUsage();
#else
        var pre = neko.vm.Gc.stats().heap;
        neko.vm.Gc.run(false);
        var post = neko.vm.Gc.stats().heap;
#end
        return Compacted(pre, post);
    }

    private function collect() : Message
    {
#if cpp
        var pre = cpp.vm.Gc.memUsage();
        cpp.vm.Gc.run(true);
        var post = cpp.vm.Gc.memUsage();
#else
        var pre = neko.vm.Gc.stats().heap;
        neko.vm.Gc.run(true);
        var post = neko.vm.Gc.stats().heap;
#end
        return Collected(pre, post);
    }

    private function setCurrentThread(number: Int) : Message
    {
        var threadInfos = Debugger.getThreadInfos();

        mStateMutex.acquire();

        if (number == mCurrentThreadNumber) {
            mStateMutex.release();
            return CurrentThread(number);
        }

        for (ti in threadInfos) {
            if (ti.number == number) {
                mCurrentThreadNumber = number;
                if (ti.status == ThreadInfo.STATUS_RUNNING) {
                    mCurrentThreadInfo = null;
                }
                else {
                    mCurrentThreadInfo = ti;
                    mCurrentStackFrame = ti.stack.length - 1;
                }
                mStateMutex.release();
                return CurrentThread(number);
            }
        }

        mStateMutex.release();

        return ErrorNoSuchThread(number);
    }

    private function addFileLineBreakpoint(fileName : String,
                                           lineNumber : Int) : Message
    {
        var desc = (fileName + ":" + lineNumber);

        if (!mBreakpointsByDescription.exists(desc)) {
            var files = Debugger.getFiles();
            for (f in files) {
                if (f == fileName) {
                    var breakpoint =
                        new Breakpoint(mNextBreakpointNumber++, desc);
                    mBreakpoints.set(breakpoint.number, breakpoint);
                    mBreakpointsByDescription.set(desc, breakpoint);
                    breakpoint.addFileLine(fileName, lineNumber);
                    break;
                }
            }
        }

        if (mBreakpointsByDescription.exists(desc)) {
            var breakpoint = mBreakpointsByDescription.get(desc);
            breakpoint.enable();
            return FileLineBreakpointNumber(breakpoint.number);
        }
        else {
            return ErrorNoSuchFile(fileName);
        }
    }

    private function addClassFunctionBreakpoint(className : String,
                                                functionName : String) : Message
    {
        var classNameRegex : EReg = null;
        var functionNameRegex : EReg = null;

        try {
            if (className.charAt(0) == "/") {
                classNameRegex =
                    new EReg(className.substr(1, className.length - 2), "");
            }
        }
        catch (e : Dynamic) {
            return ErrorBadClassNameRegex(e);
        }

        try {
            if (functionName.charAt(0) == "/") {
                functionNameRegex =
                    new EReg(functionName.substr
                             (1, functionName.length - 2), "");
            }
        }
        catch (e : Dynamic) {
            return ErrorBadFunctionNameRegex(e);
        }

        var desc = className + "." + functionName;

        if (mBreakpointsByDescription.exists(desc)) {
            var breakpoint = mBreakpointsByDescription.get(desc);
            breakpoint.enable();
            return ClassFunctionBreakpointNumber
                (breakpoint.number, Terminator);
        }

        var badClasses : StringList = Terminator;

        var classNames = Debugger.getClasses();
        for (cn in classNames) {
            var matchesClass = false;
            if (classNameRegex == null) {
                if (cn == className) {
                    matchesClass = true;
                }
                else {
                    var last = cn.lastIndexOf(".");
                    if (last != -1) {
                        if (cn.substr(last + 1) == className) {
                            matchesClass = true;
                        }
                    }
                }
            }
            else if (classNameRegex.match(cn)) {
                matchesClass = true;
            }
            if (!matchesClass) {
                continue;
            }
            var klass = Type.resolveClass(cn);
            if (klass == null) {
                badClasses = Element(cn, badClasses);
            }
            else {
                this.breakFunction(desc, cn, klass, functionName,
                                   functionNameRegex);
            }
        }

        if (mBreakpointsByDescription.exists(desc)) {
            var breakpoint = mBreakpointsByDescription.get(desc);
            breakpoint.enable();
            return ClassFunctionBreakpointNumber
                (breakpoint.number, badClasses);
        }
        else {
            return ErrorNoMatchingFunctions
                (className, functionName, badClasses);
        }
    }

    private function breakFunction(desc : String, className : String,
                                   klass : Class<Dynamic>,
                                   functionName : String,
                                   functionNameRegex : EReg)
    {
        // First of all, any new function matches implicitly
        if (functionName == "new") {
            this.addFunctionBreakpoint(desc, className, functionName);
        }

        // Try to match the function within the class
        for (f in Type.getClassFields(klass).concat
                 (Type.getInstanceFields(klass))) {
            if (!Reflect.isFunction(Reflect.field(klass, f))) {
                continue;
            }
            var matchesFunction = false;
            if (functionNameRegex == null) {
                if (f == functionName) {
                    matchesFunction = true;
                }
            }
            else if (functionNameRegex.match(f)) {
                matchesFunction = true;
            }
            if (matchesFunction) {
                this.addFunctionBreakpoint(desc, className, f);
                if (functionNameRegex == null) {
                    return;
                }
            }
        }
    }

    private function addFunctionBreakpoint(desc : String, className : String,
                                           functionName : String)
    {
        var breakpoint : Breakpoint = mBreakpointsByDescription.get(desc);
        if (breakpoint == null) {
            breakpoint = new Breakpoint(mNextBreakpointNumber++, desc);
            mBreakpoints.set(breakpoint.number, breakpoint);
            mBreakpointsByDescription.set(desc, breakpoint);
        }

        breakpoint.addClassFunction(className, functionName);
    }

    private function listBreakpoints(enabled, disabled) : Message
    {
        var list : BreakpointList = Terminator;

        var breakpoints : Array<Breakpoint> = new Array<Breakpoint>();

        for (k in mBreakpoints.keys()) {
            var breakpoint = mBreakpoints.get(k);
            if ((enabled && breakpoint.enabled) ||
                (disabled && !breakpoint.enabled)) {
                breakpoints.push(breakpoint);
            }
        }

        breakpoints.sort(function (a : Breakpoint, b : Breakpoint) {
                return b.number - a.number; });

        for (b in breakpoints) {
            list = Breakpoint(b.number, b.description, b.enabled,
                              (b.bpCount() > 1), list);
        }

        return Breakpoints(list);
    }

    private function describeBreakpoint(number : Int) : Message
    {
        var breakpoint = mBreakpoints.get(number);

        if (breakpoint == null) {
            return ErrorNoSuchBreakpoint(number);
        }

        var list : BreakpointLocationList = Terminator;

        for (b in breakpoint.bps()) {
            switch (b) {
            case BP.FileLine(bp, fileName, lineNumber):
                list = BreakpointLocationList.FileLine(fileName, lineNumber, list);
            case BP.ClassFunction(bp, className, functionName):
                list = BreakpointLocationList.ClassFunction(className, functionName, list);
            }
        }

        return BreakpointDescription(number, list);
    }

    private function disableAllBreakpoints() : Message
    {
        return this.disableBreakpointRange(-1, -1);
    }

    private function disableBreakpointRange(first, last) : Message
    {
        var list : BreakpointStatusList = Terminator;

        for (i in getBreakpointIds(first, last)) {
            var breakpoint = mBreakpoints.get(i);
            if (breakpoint == null) {
                list = Nonexistent(i, list);
                continue;
            }
            if (breakpoint.enabled) {
                breakpoint.disable();
                list = Disabled(i, list);
            }
            else {
                list = AlreadyDisabled(i, list);
            }
        }

        return BreakpointStatuses(list);
    }

    private function enableAllBreakpoints() : Message
    {
        return this.enableBreakpointRange(-1, -1);
    }

    private function enableBreakpointRange(first, last) : Message
    {
        var list : BreakpointStatusList = Terminator;

        for (i in getBreakpointIds(first, last)) {
            var breakpoint = mBreakpoints.get(i);
            if (breakpoint == null) {
                list = Nonexistent(i, list);
                continue;
            }
            if (breakpoint.enabled) {
                list = AlreadyEnabled(i, list);
            }
            else {
                breakpoint.enable();
                list = Enabled(i, list);
            }
        }

        return BreakpointStatuses(list);
    }

    private function deleteAllBreakpoints() : Message
    {
        return this.deleteBreakpointRange(-1, -1);
    }

    private function deleteBreakpointRange(first, last) : Message
    {
        var list : BreakpointStatusList = Terminator;

        for (i in getBreakpointIds(first, last)) {
            var breakpoint = mBreakpoints.get(i);
            if (breakpoint == null) {
                list = Nonexistent(i, list);
                continue;
            }
            mBreakpoints.remove(i);
            mBreakpointsByDescription.remove(breakpoint.description);
            breakpoint.delete();
            list = Deleted(i, list);
        }

        return BreakpointStatuses(list);
    }

    private function breakNow() : Message
    {
        Debugger.breakNow();
        return OK;
    }

    private function continueCurrent(count : Int) : Message
    {
        if (count < 1) {
            return ErrorBadCount(count);
        }

        Debugger.continueThreads(mCurrentThreadNumber, count);

        return Continued(count);
    }

    private function step(count) : Message
    {
        return this.stepExecution(count, Debugger.STEP_INTO);
    }

    private function next(count) : Message
    {
        return this.stepExecution(count, Debugger.STEP_OVER);
    }

    private function finish(count) : Message
    {
        return this.stepExecution(count, Debugger.STEP_OUT);
    }

    private function whereCurrentThread(unsafe : Bool) : Message
    {
        // Latch the current thread number, because it may change, and the
        // value used in any print calls should match the value used in the
        // getThreadInfo call
        mStateMutex.acquire();

        var threadInfo : ThreadInfo = this.getCurrentThreadInfoLocked(unsafe);

        if (threadInfo == null) {
            mStateMutex.release();
            return ErrorCurrentThreadNotStopped(mCurrentThreadNumber);
        }

        if (mCurrentStackFrame == -1) {
            mCurrentStackFrame = threadInfo.stack.length - 1;
        }

        mStateMutex.release();

        return ThreadsWhere
            (threadInfoToThreadWhereLocked(threadInfo, Terminator));
    }

    private function whereAllThreads() : Message
    {
        var threadInfos = Debugger.getThreadInfos();
        if (threadInfos.length == 0) {
            return ThreadsWhere(Terminator);
        }

        var list : ThreadWhereList = Terminator;

        for (ti in threadInfos) {
            list = threadInfoToThreadWhereLocked(ti, list);
        }

        return ThreadsWhere(list);
    }

    private function threadInfoToThreadWhereLocked(threadInfo : ThreadInfo,
                                      next : ThreadWhereList) : ThreadWhereList
    {
        var list : FrameList = Terminator;

        if (threadInfo.stack.length > 0) {
            var frameNumber = 0;

            for (sf in threadInfo.stack) {
                list = Frame(((threadInfo.number == mCurrentThreadNumber) &&
                              (frameNumber == mCurrentStackFrame)),
                             frameNumber, sf.className, sf.functionName,
                             sf.fileName, sf.lineNumber, list);
                frameNumber += 1;
            }
        }

        var threadStatus : ThreadStatus;

        switch (threadInfo.status) {
        case ThreadInfo.STATUS_RUNNING:
            threadStatus = Running;
        case ThreadInfo.STATUS_STOPPED_BREAK_IMMEDIATE:
            threadStatus = StoppedImmediate;
        case ThreadInfo.STATUS_STOPPED_BREAKPOINT:
            threadStatus = StoppedBreakpoint
                (this.findBreakpoint(threadInfo.breakpoint));
        case ThreadInfo.STATUS_STOPPED_UNCAUGHT_EXCEPTION:
            threadStatus = StoppedUncaughtException;
        default: // ThreadInfo.STATUS_STOPPED_CRITICAL_ERROR
            threadStatus = StoppedCriticalError
                (threadInfo.criticalErrorDescription);
        }

        return Where(threadInfo.number, threadStatus, list, next);
    }

    private function up(count : Int) : Message
    {
        if (count < 1) {
            return ErrorBadCount(count);
        }

        mStateMutex.acquire();

        var threadInfo : ThreadInfo = this.getCurrentThreadInfoLocked();

        if (threadInfo == null) {
            mStateMutex.release();
            return ErrorCurrentThreadNotStopped(mCurrentThreadNumber);
        }

        mCurrentStackFrame -= count;
        if (mCurrentStackFrame < 0) {
            mCurrentStackFrame = 0;
        }

        count = mCurrentStackFrame;

        mStateMutex.release();

        return CurrentFrame(count);
    }

    private function down(count : Int) : Message
    {
        if (count < 1) {
            return ErrorBadCount(count);
        }

        mStateMutex.acquire();

        var threadInfo : ThreadInfo = this.getCurrentThreadInfoLocked();

        if (threadInfo == null) {
            mStateMutex.release();
            return ErrorCurrentThreadNotStopped(mCurrentThreadNumber);
        }

        var max_stack = threadInfo.stack.length - 1;

        mCurrentStackFrame += count;
        if (mCurrentStackFrame > max_stack) {
            mCurrentStackFrame = max_stack;
        }

        count = mCurrentStackFrame;

        mStateMutex.release();

        return CurrentFrame(count);
    }

    private function setFrame(number : Int) : Message
    {
        mStateMutex.acquire();

        var threadInfo : ThreadInfo = this.getCurrentThreadInfoLocked();

        if (threadInfo == null) {
            mStateMutex.release();
            return ErrorCurrentThreadNotStopped(mCurrentThreadNumber);
        }

        mCurrentStackFrame = number;

        if (mCurrentStackFrame < 0) {
            mCurrentStackFrame = 0;
        }
        else {
            var max_stack = threadInfo.stack.length - 1;
            if (mCurrentStackFrame > max_stack) {
                mCurrentStackFrame = max_stack;
            }
        }

        number = mCurrentStackFrame;

        mStateMutex.release();

        return CurrentFrame(number);
    }

    private function variables(unsafe : Bool) : Message
    {
        mStateMutex.acquire();

        // Just to ensure that the current stack frame is known
        this.getCurrentThreadInfoLocked();

        var variables : Array<String> = Debugger.getStackVariables
            (mCurrentThreadNumber, mCurrentStackFrame, unsafe);

        if ((variables.length == 1) &&
            (variables[0] == Debugger.THREAD_NOT_STOPPED)) {
            mStateMutex.release();
            return ErrorCurrentThreadNotStopped(mCurrentThreadNumber);
        }

        mStateMutex.release();

        var list : StringList = Terminator;

        // Sort the variables in reverse so that the list can be created easily
        variables.sort(function (a : String, b : String) {
                return Reflect.compare(b, a);
            });

        for (f in variables) {
            list = Element(f, list);
        }

        return Variables(list);
    }

    private function printExpression(unsafe : Bool,
                                     expression : String) : Message
    {
        mStateMutex.acquire();

        // Just to ensure that the current stack frame is known
        this.getCurrentThreadInfoLocked();

        try {
            var value : Dynamic = ExpressionHelper.getValue
                (expression, { threadNumber : mCurrentThreadNumber,
                               stackFrame : mCurrentStackFrame,
                               dbgVars : mDebuggerVariables,
                               unsafe : unsafe });

            mStateMutex.release();

            return Message.Value(StringTools.trim(expression),
                         TypeHelpers.getValueTypeName(value),
                         TypeHelpers.getValueString(value));
        }
        catch (e : Dynamic) {
            mStateMutex.release();
            if (e == Debugger.NONEXISTENT_VALUE) {
                return ErrorEvaluatingExpression("No such value");
            }
            else if (e == Debugger.THREAD_NOT_STOPPED) {
                return ErrorCurrentThreadNotStopped(mCurrentThreadNumber);
            }
            else {
                return ErrorEvaluatingExpression(e);
            }
        }
    }

    private function setExpression(unsafe : Bool, lhs : String,
                                   rhs : String) : Message
    {
        mStateMutex.acquire();

        // Just to ensure that the current stack frame is known
        this.getCurrentThreadInfoLocked();

        try {
            var value : Dynamic = ExpressionHelper.setValue
                (lhs, rhs, { threadNumber : mCurrentThreadNumber,
                             stackFrame : mCurrentStackFrame,
                             dbgVars : mDebuggerVariables,
                             unsafe : unsafe });

            mStateMutex.release();

            return Message.Value(StringTools.trim(lhs),
                         TypeHelpers.getValueTypeName(value),
                         TypeHelpers.getValueString(value));
        }
        catch (e : Dynamic) {
            mStateMutex.release();
            if (e == Debugger.NONEXISTENT_VALUE) {
                return ErrorEvaluatingExpression("No such value");
            }
            else if (e == Debugger.THREAD_NOT_STOPPED) {
                return ErrorCurrentThreadNotStopped(mCurrentThreadNumber);
            }
            else {
                return ErrorEvaluatingExpression(e);
            }
        }
    }

    private function getBreakpointIds(first : Int, last : Int)
        : Iterator<Int>
    {
        var sorted = new Array<Int>();

        if (first == -1) {
            for (k in mBreakpoints.keys()) {
                sorted.push(k);
            }
            sorted.sort(function (a : Int, b : Int) { return b - a; });
        }
        else {
            for (i in first ... (last + 1)) {
                sorted.unshift(i);
            }
        }

        return sorted.iterator();
    }

    private function stepExecution(count : Int, type : Int) : Message
    {
        if (count < 1) {
            return ErrorBadCount(count);
        }

        Debugger.stepThread(mCurrentThreadNumber, type, count);

        return Continued(count);
    }

    // Find by a debugger breakpoint number given the breakpoint field of a
    // ThreadInfo
    private function findBreakpoint(bpNumber : Int) : Int
    {
        for (breakpoint in mBreakpoints) {
            for (bp in breakpoint.bps()) {
                switch (bp) {
                case FileLine(bp, fileName, lineNumber):
                    if (bp == bpNumber) {
                        return breakpoint.number;
                    }
                case ClassFunction(bp, className, functionName):
                    if (bp == bpNumber) {
                        return breakpoint.number;
                    }
                }
            }
        }

        // Hm, no such breakpoint
        return -1;
    }

    private function getCurrentThreadInfoLocked
                                           (unsafe : Bool = false) : ThreadInfo
    {
        if (unsafe) {
            mCurrentThreadInfo = null;
            return Debugger.getThreadInfo(mCurrentThreadNumber, unsafe);
        }

        if (mCurrentThreadInfo != null) {
            return mCurrentThreadInfo;
        }

        mCurrentThreadInfo = Debugger.getThreadInfo
            (mCurrentThreadNumber, unsafe);

        if (mCurrentThreadInfo == null) {
            return null;
        }

        mCurrentStackFrame = mCurrentThreadInfo.stack.length - 1;

        return mCurrentThreadInfo;
    }

    // This is a mutex that prevents simultaneous access of member variables
    // by the event handler thread and the debugger thread.
    private var mStateMutex : Mutex;
    private var mController : IController;
    // mCurrentThreadNumber starts out as the thread that created the debugger
    // instance.
    private var mCurrentThreadNumber : Int;
    private var mCurrentStackFrame : Int;
    private var mCurrentThreadInfo : ThreadInfo;
    private var mBreakpoints : haxe.ds.IntMap<Breakpoint>;
    private var mBreakpointsByDescription : haxe.ds.StringMap<Breakpoint>;
    private var mNextBreakpointNumber : Int;

    private var mDebuggerVariables : DebuggerVariables;

    private static var gStartMutex : Mutex = new Mutex();
    private static var gStarted : Bool = false;
    private static var gStartStopped : Bool;
    private static var gStartQueue : Deque<Bool> = new Deque<Bool>();
}


private class TypeHelpers
{
    public static function getValueTypeName(value : Dynamic) : String
    {
        switch (Type.typeof(value)) {
        case TUnknown:
            return "UNKNOWN";
        case TNull:
            return "NULL";
        case TObject:
            return "Class<T>";
        case TInt:
            return "Int";
        case TFunction:
            return "Function";
        case TFloat:
            return "Float";
        case TEnum(e):
            return Type.getEnumName(e);
        case TClass(Array):
            var arr = cast(value, Array<Dynamic>);
            if (arr.length == 0) {
                return "Array<>";
            }
            else {
                return ("Array<" + getValueTypeName(arr[0]) + ">[" +
                        arr.length + "]");
            }
        case TClass(DebuggerVariables):
            return "Debugger variables";
        case TClass(c):
            return Type.getClassName(c);
        case TBool:
            return "Bool";
        }

        return "INVALID";
    }

    public static function getValueString(value : Dynamic, indent : String = "",
                                      ellipseForObjects : Bool = false) : String
    {
        switch (Type.typeof(value)) {
        case TUnknown:
        case TInt:
        case TBool:
        case TFloat:
        case TEnum(e):
        case TNull:
        case TFunction:
            return Std.string(value);
        case TObject:
            return ("Class<" + Std.string(value) + ">" +
                    getClassValueString(value, indent));
        case TClass(Array):
            var arr : Array<Dynamic> = cast value;
            if (arr.length == 0) {
                return "[ ]";
            }
            if (ellipseForObjects) {
                return "[ ... ]";
            }
            var ret = "[ ";
            var needComma = false;
            for (a in arr) {
                if (needComma) {
                    ret += ", ";
                }
                else {
                    needComma = true;
                }
                ret += getValueString(a, indent);
            }
            return ret + " ]";
        case TClass(String):
            return "\"" + value + "\"";
        case TClass(DebuggerVariables):
            return value.toString();
        case TClass(c):
            if (ellipseForObjects) {
                return "...";
            }
            var klass = Type.getClass(value);
            if (klass == null) {
                return "???";
            }
            return getInstanceValueString(Type.getClass(value), value, indent);
        }

        return Std.string(value);
    }

    public static function getClassValueString(klass : Class<Dynamic>,
                                               indent : String) : String
    {
        var ret = "\n" + indent + "{\n";

        var fields = new Array<String>();

        for (f in Type.getClassFields(klass)) {
            if (Reflect.isFunction(Reflect.field(klass, f))) {
                continue;
            }
            fields.push(f);
        }

        for (f in fields) {
            var fieldValue = Reflect.getProperty(klass, f);
            ret += (indent + "    " + f + " : static " +
                    getValueTypeName(fieldValue) + " = " +
                    getValueString(fieldValue, indent + "    ", true) + "\n");
        }

        return ret + indent + "}";
    }

    public static function getInstanceValueString(klass : Class<Dynamic>,
                                                  value : Dynamic,
                                                  indent : String) : String
    {
        var ret = "\n" + indent + "{\n";

        // Type seems to return the fields in the reverse order as they
        // are defined in the source ...
        var fields = new Array<String>();

        for (f in Type.getInstanceFields(klass)) {
            if (Reflect.isFunction(Reflect.field(value, f))) {
                continue;
            }
            fields.unshift(f);
        }

        for (f in fields) {
            var fieldValue = Reflect.getProperty(value, f);
            ret += (indent + "    " + f + " : " +
                    getValueTypeName(fieldValue) + " = " +
                    getValueString(fieldValue, indent + "    ", true) + "\n");
        }

        fields = new Array<String>();

        // Although the instance fields returned by Type seem to include super
        // class variables also, class variables do not, so iterate through
        // super classes manually
        while (klass != null) {
            for (f in Type.getClassFields(klass)) {
                if (Reflect.isFunction(Reflect.field(value, f))) {
                    continue;
                }
                fields.push(f);
            }
            klass = Type.getSuperClass(klass);
        }

        for (f in fields) {
            var fieldValue = Reflect.getProperty(value, f);
            ret += (indent + "    " + f + " : static " +
                    getValueTypeName(fieldValue) + " = " +
                    getValueString(fieldValue, indent + "    ", true) + "\n");
        }

        return ret + indent + "}";
    }
}


private class DebuggerVariables
{
    public function new()
    {
        mMap = new haxe.ds.StringMap<Dynamic>();
    }

    public function set(key : String, value : Dynamic)
    {
        if (value == null) {
            mMap.remove(key);
        }
        else {
            mMap.set(key, value);
        }
    }

    public function get(key : String) : Dynamic
    {
        return mMap.get(key);
    }

    public function toString() : String
    {
        var keys : Array<String> = new Array<String>();

        var iter = mMap.keys();

        var ret = "\n\n";

        if (!iter.hasNext()) {
            return ret + "(no values)";
        }

        for (k in iter) {
            keys.push(k);
        }

        keys.sort(function (a : String, b : String) {
                return Reflect.compare(a, b);
            });

        var needNewline = false;
        for (k in keys) {
            if (needNewline) {
                ret += "\n";
            }
            else {
                needNewline = true;
            }
            var value = mMap.get(k);
            ret += ("$." + k + " : " + TypeHelpers.getValueTypeName(value) +
                    " = " + TypeHelpers.getValueString(value));
        }

        return ret;
    }

    private var mMap : haxe.ds.StringMap<Dynamic>;
}


private enum BP
{
    FileLine(bp : Int, fileName : String, lineNumber : Int);
    ClassFunction(bp : Int, className : String, functionName : String);
}


private class Breakpoint
{
    public var number(default, null) : Int;
    public var description(default, null) : String;
    public var enabled(default, null) : Bool;
    public var continueCount(default, null) : Int;

    public function new(num : Int, desc : String)
    {
        this.number = num;
        this.description = desc;
        this.enabled = true;
        this.mBps = new Array<BP>();
    }

    public function delete()
    {
        for (b in mBps) {
            switch (b) {
            case BP.FileLine(bp, fileName, lineNumber):
                Debugger.deleteBreakpoint(bp);
            case BP.ClassFunction(bp, className, functionName):
                Debugger.deleteBreakpoint(bp);
            }
        }
    }

    public function addFileLine(fileName : String, lineNumber : Int)
    {
        mBps.push(BP.FileLine(Debugger.addFileLineBreakpoint
                              (fileName, lineNumber), fileName, lineNumber));
    }

    public function addClassFunction(className : String, functionName : String)
    {
        mBps.push(BP.ClassFunction(Debugger.addClassFunctionBreakpoint
                                   (className, functionName), className,
                                   functionName));
    }

    public function bpCount() : Int
    {
        return mBps.length;
    }

    public function bps() : Iterator<BP>
    {
        return mBps.iterator();
    }

    public function enable()
    {
        if (this.enabled) {
            return;
        }

        var oldBps = mBps;
        mBps = new Array<BP>();

        for (b in oldBps) {
            switch (b) {
            case BP.FileLine(bp, fileName, lineNumber):
                this.addFileLine(fileName, lineNumber);
            case BP.ClassFunction(bp, className, functionName):
                this.addClassFunction(className, functionName);
            }
        }

        this.enabled = true;
    }

    public function disable()
    {
        if (!this.enabled) {
            return;
        }

        for (b in mBps) {
            switch (b) {
            case BP.FileLine(bp, fileName, lineNumber):
                Debugger.deleteBreakpoint(bp);
            case BP.ClassFunction(bp, className, functionName):
                Debugger.deleteBreakpoint(bp);
            }
        }

        this.enabled = false;
    }

    private var mBps : Array<BP>;
}


/**
 * Convenience typedef
 **/
typedef DbgVarSrc = { var threadNumber : Int;
                      var stackFrame : Int;
                      var dbgVars : DebuggerVariables;
                      var unsafe : Bool; };

// This is a helper class that can parse Haxe expressions and evaluate them
// into values, or use them to set references to other values
private class ExpressionHelper
{
    public static function getValue(str : String, varSrc : DbgVarSrc) : Dynamic
    {
        try {
            var parsed = ElementParser.parse(str, 0);
            return getElementValue(parsed, varSrc);
        }
        catch (e : ElementException) {
            throw (e.reason + ": " + str.substr(0, e.begin) + " -> " +
                   str.substr(e.begin, e.end + 1) + " <- " +
                   str.substr(e.end + 1));
        }
    }

    public static function setValue(lhs : String, rhs : String,
                                    varSrc : DbgVarSrc) : Dynamic
    {
        var lhs_element;

        try {
            lhs_element = ElementParser.parse(lhs, 0);
        }
        catch (e : ElementException) {
            throw (e.reason + ": " + lhs.substr(0, e.begin) + " -> " +
                   lhs.substr(e.begin, e.end + 1) + " <- " +
                   lhs.substr(e.end + 1));
        }

        var lhs_expr = getExpression(lhs_element, varSrc);

        var rhs_value = getValue(rhs, varSrc);

        switch (lhs_expr) {
        case ExpressionEnum.Value(value):
            throw "Cannot set value";
        case ExpressionEnum.FieldRef(value, field):
            Reflect.setProperty(value, field, rhs_value);
        case ExpressionEnum.DebuggerFieldRef(field):
            varSrc.dbgVars.set(field, rhs_value);
        case ExpressionEnum.DebuggerFields:
            throw "Cannot assign a value to $";
        case ExpressionEnum.ArrayRef(value, index):
            var arr : Array<Dynamic> = cast value;
            arr[index] = rhs_value;
        case ExpressionEnum.StackRef(name):
            return Debugger.setStackVariableValue
                (varSrc.threadNumber, varSrc.stackFrame, name, rhs_value,
                 varSrc.unsafe);
        }

        return rhs_value;
    }

    // Convert an element into its actual Haxe value
    private static function getElementValue(e : ElementEnum,
                                            varSrc : DbgVarSrc) : Dynamic
    {
        var expr = getExpression(e, varSrc);

        switch (expr) {
        case ExpressionEnum.Value(value):
            return value;
        case ExpressionEnum.FieldRef(value, field):
            return Reflect.getProperty(value, field);
        case ExpressionEnum.DebuggerFieldRef(field):
            var value = varSrc.dbgVars.get(field);
            if (value == null) {
                throw "No such debugger variable $." + field;
            }
            return value;
        case ExpressionEnum.DebuggerFields:
            return varSrc.dbgVars;
        case ExpressionEnum.ArrayRef(value, index):
            var arr : Array<Dynamic> = cast value;
            if (index >= arr.length) {
                throw "Out-of-bounds array reference";
            }
            return arr[index];
        case ExpressionEnum.StackRef(name):
            return getStackValue(name, varSrc);
        }
    }

    // This is some really hairy stuff.  This converts an ElementEnum into
    // an ExpressionEnum, which means that any values must be resolved and any
    // function calls must be made, and that can be really complicated
    private static function getExpression(e : ElementEnum,
                                          varSrc : DbgVarSrc) : ExpressionEnum
    {
        switch (e) {
        case ElementEnum.Value(value, value_begin, value_end):
            // Resolve the value and make a Value out of it
            return ExpressionEnum.Value(resolveValue(value, varSrc));

        case ElementEnum.Array_Value(array):
            // Compose an array and convert all of the array elements into it
            var arr : Array<Dynamic> = new Array<Dynamic>();
            for (element in array) {
                // Convert the element into a value and push it onto the array
                arr.push(getElementValue(element, varSrc));
            }
            // The array is the Value
            return ExpressionEnum.Value(arr);

        case ElementEnum.Field(element, field, field_begin, field_end):
            // Convert the element directly into a value and make a field
            // ref out of it and the field name
            return ExpressionEnum.FieldRef(getElementValue(element, varSrc),
                                           field);

        case ElementEnum.DebuggerField(field, field_begin, field_end):
            return ExpressionEnum.DebuggerFieldRef(field);

        case ElementEnum.DebuggerFields:
            return ExpressionEnum.DebuggerFields;

        case ElementEnum.Array_Element(element, index):
            // Get the array
            var array = getElementValue(element, varSrc);
            var indexValue = getElementValue(index, varSrc);
            switch (Type.typeof(indexValue)) {
            case TInt:
                // Convert the element directly into a value and make an array
                // ref out of it and the index
                return ExpressionEnum.ArrayRef
                    (getElementValue(element, varSrc), cast indexValue);
            default:
                throw "Non-integer array index";
            }

        case ElementEnum.Function_Call(element, parameters):
            // o will be the object to call the function on
            var o : Dynamic = null;
            // func will be the function to call
            var func : Dynamic = null;
            switch (element) {
            case ElementEnum.Value(value, value_begin, value_end):
                throw "Cannot call a function on a value";
            case ElementEnum.Array_Value(array):
                throw "Cannot call a function on an array";
            case ElementEnum.Field(inner_element, field,
                                   field_begin, field_end):
                // The function to call is a field of an object.  Functions
                // which are fields of objects take the object themselves as
                // the object to call the function on
                o = getElementValue(inner_element, varSrc);
                func = Reflect.getProperty(o, field);
            case ElementEnum.DebuggerField(field, field_begin, field_end):
                // The function to call is a field of the special debugger
                // variable hash table; it cannot take an "this" parameter
                func = getElementValue(element, varSrc);
            case ElementEnum.DebuggerFields:
                throw "Cannot call a function on $";
            case ElementEnum.Array_Element(inner_element, index):
                // Function calls inside arrays do not take any "this"
                // parameter so leave o as null
                func = getElementValue(element, varSrc);
            case ElementEnum.Function_Call(inner_element, inner_parameters):
                // Functions returned function calls cannot take a "this"
                // parameter so leave o as null
                func = getElementValue(element, varSrc);
            case ElementEnum.Constructor_Call(class_name, parameters,
                                              class_name_begin, class_name_end):
                // There is no way that an object created by a constructor
                // can be used as a function
                throw "Cannot call a function on a constructed object";
            case ElementEnum.Path(path, path_begin, path_end):
                func = getElementValue(element, varSrc);
            }
            if ((func == null) || !Reflect.isFunction(func)) {
                throw "No such function";
            }
            // Convert the args into Dynamics from their ElementEnum form
            var args : Array<Dynamic> = new Array<Dynamic>();
            for (p in parameters) {
                args.push(getElementValue(p, varSrc));
            }
            return ExpressionEnum.Value(Reflect.callMethod(o, func, args));

        case ElementEnum.Constructor_Call(class_name, parameters,
                                          class_name_begin, class_name_end):
            var klass = Type.resolveClass(class_name);
            if (klass == null) {
                throw "Cannot resolve class " + class_name;
            }
            var args : Array<Dynamic> = new Array<Dynamic>();
            for (p in parameters) {
                args.push(getElementValue(p, varSrc));
            }
            return ExpressionEnum.Value(Type.createInstance(klass, args));

        case ElementEnum.Path(path, path_begin, path_end):
            return resolvePath(path, varSrc);
        }
    }

    private static function getStackValue(name : String,
                                          varSrc : DbgVarSrc) : Dynamic
    {
        var value : Dynamic = Debugger.getStackVariableValue
            (varSrc.threadNumber, varSrc.stackFrame, name, varSrc.unsafe);

        if (value == Debugger.THREAD_NOT_STOPPED) {
            throw value;
        }

        if (value == Debugger.NONEXISTENT_VALUE) {
            throw value;
        }

        return value;
    }

    private static function join(arr : Array<String>, sep : String,
                                 begin : Int, end : Int) : String
    {
        var ret = "";

        for (i in begin ... end) {
            ret += arr[i] + sep;
        }

        if (end < arr.length) {
            ret += arr[end];
        }

        return ret;
    }

    // The path element comes at the beginning of the expression.  Resolve
    // it into the possible types that it can be (a string, number, boolean,
    // etc constant, or a class reference, or a stack variable reference, or a
    // field reference of a class or stack variable).
    private static function resolvePath(path : String,
                                        varSrc : DbgVarSrc) : ExpressionEnum
    {
        var arr = path.split(".");

        // Try to resolve to the magic debugger variable container or a
        // reference to a magic debugger variable debugger

        if (arr[0] == "$") {
            if (arr.length == 1) {
                return ExpressionEnum.DebuggerFields;
            }
            if (arr.length == 2) {
                return ExpressionEnum.DebuggerFieldRef(arr[1]);
            }
            var value : Dynamic = varSrc.dbgVars.get(arr[1]);
            if (value == null) {
                throw "No value";
            }
            var result = resolveField(value, arr, 2);
            if (result == null) {
                throw "No value " + path;
            }
            return result;
        }

        // Try to resolve to a constant

        try {
            return ExpressionEnum.Value(resolveConstant(path));
        }
        catch (e : Dynamic) {
            // It wasn't a constant; proceed
        }

        // Try to resolve to a static class or static class field

        for (index in 0 ... arr.length) {
            var klass = Type.resolveClass(join(arr, ".", 0, index));
            if (klass == null) {
                continue;
            }
            if (index == (arr.length - 1)) {
                // There's no value to look for, the path was to a class
                return ExpressionEnum.Value(klass);
            }
            // Try to find the static value within the class
            var result = resolveField(klass, arr, index + 1);
            if (result != null) {
                return result;
            }
        }

        // Try to resolve to a stack field reference
        var value : Dynamic = Debugger.getStackVariableValue
            (varSrc.threadNumber, varSrc.stackFrame, arr[0], varSrc.unsafe);

        // Can't resolve fields on running threads.
        if (value == Debugger.THREAD_NOT_STOPPED) {
            throw value;
        }

        if (value == Debugger.NONEXISTENT_VALUE) {
            // Try to get it as a field of "this"
            value = Debugger.getStackVariableValue
                (varSrc.threadNumber, varSrc.stackFrame, "this",
                 varSrc.unsafe);
            if (value == Debugger.THREAD_NOT_STOPPED) {
                throw value;
            }
            else if (value == Debugger.NONEXISTENT_VALUE) {
                throw value;
            }

            if (value == null) {
                throw "Null dereference " + arr[0];
            }

            var result = resolveField(value, arr, 0);

            if (result == null) {
                throw "No value " + path;
            }

            return result;
        }
        // Else got the value
        else {
            // If there was no field reference, then it's just the stack value
            if (arr.length == 1) {
                return ExpressionEnum.StackRef(arr[0]);
            }

            if (value == null) {
                throw "Null dereference " + arr[0];
            }

            var result = resolveField(value, arr, 1);

            if (result == null) {
                throw "No value " + path;
            }

            return result;
        }
    }

    private static function resolveField(value : Dynamic, arr : Array<String>,
                                         index : Int) : Null<ExpressionEnum>
    {
        var klass : Class<Dynamic>;
        switch (Type.typeof(value)) {
        // TObject means that value is already a Class<Dynamic>
        case TObject:
            klass = value;
        case TClass(c):
            klass = Type.getClass(value);
        default:
            // The remaining types cannot have fields
            return null;
        }

        var found = false;

        for (f in Type.getInstanceFields(klass).concat
                 (Type.getClassFields(klass))) {
            if (f == arr[index]) {
                found = true;
                break;
            }
        }

        if (!found) {
            // Try the super class
            klass = Type.getSuperClass(klass);
            if (klass != null) {
                return resolveField(klass, arr, index);
            }
            return null;
        }

        if (index == (arr.length - 1)) {
            return ExpressionEnum.FieldRef(value, arr[index]);
        }

        value = Reflect.getProperty(value, arr[index]);

        if (value == null) {
            throw "Null value dereference " + join(arr, ".", 0, index);
        }

        return resolveField(value, arr, index + 1);
    }

    // Throws an exception if the value cannot be resolved to a constant
    private static function resolveConstant(value : String) : Dynamic
    {
        // String constant
        if (value.charAt(0) == "\"") {
            return value.substring(1, value.length - 1);
        }
        // Bool constant
        else if (value == "true") {
            return true;
        }
        else if (value == "false") {
            return false;
        }
        else if (value == "null") {
            return null;
        }
        // Int/Float constant
        else if (gNumberRegex.match(value)) {
            if (gNumberRegex.matched(1).length > 0) {
                return Std.parseFloat(value);
            }
            else {
                return Std.parseInt(value);
            }
        }

        throw "Not a constant";
    }

    // Convert a constant String, Int, Float, Bool, or null, or a stack
    // variable reference, into a value
    private static function resolveValue(value : String,
                                         varSrc : DbgVarSrc) : Dynamic
    {
        try {
            return resolveConstant(value);
        }
        catch (e : Dynamic) {
            // It wasn't a constant; proceed
        }

        // Can only be a stack reference otherwise
        return getStackValue(value, varSrc);
    }

    private static var gNumberRegex = ~/^-?[0-9]*(\.?)[0-9]*$/;
}


// This is a single parsed element from a Haxe value expression
private enum ElementEnum
{
    // <element>
    // value_begin is the column of the first character of the value
    // value_end is the column of the last character of the value
    Value(value : String, value_begin : Int, value_end : Int);
    // [ <element>, <element>, ... ]
    Array_Value(array : Array<ElementEnum>);
    // <element>.field
    // field_begin is the column of the first character of the field name
    // field_end is the column of the last character of the field name
    Field(element : ElementEnum, field : String,
          field_begin : Int, field_end : Int);
    // $.<field>
    // field_begin is the column of the first character of the field name
    // field_end is the column of the last character of the field name
    DebuggerField(field : String, field_begin : Int, field_end : Int);
    // $
    DebuggerFields;
    // <element>[index]
    Array_Element(element : ElementEnum, index : ElementEnum);
    // <element>(<element>, <element>, ...)
    Function_Call(element : ElementEnum, parameters : Array<ElementEnum>);
    // new <class_name>(<element>, <element>, ...)
    // class_name_begin is the column of the first character of the class name
    // class_name_end is the column of the last character of the class name
    Constructor_Call(class_name : String, parameters : Array<ElementEnum>,
                     class_name_begin : Int, class_name_end : Int);
    // This is <path>.<value> appearing only at the very beginning of the
    // string.
    Path(path : String, path_begin : Int, path_end : Int);
}


// Representation of an Expression
private enum ExpressionEnum
{
    Value(value : Dynamic);
    FieldRef(value : Dynamic, field : String);
    DebuggerFieldRef(field : String);
    DebuggerFields;
    ArrayRef(value : Dynamic, index : Int);
    StackRef(name : String);
}


// This is an exception thrown when a parsing error is encountered
private class ElementException
{
    // Ths is the reason for the error
    public var reason(default, null) : String;
    // This is the column of the first character of the invalid part of the
    // expression
    public var begin(default, null) : Int;
    // This is the column of the last character of the invalid part of the
    // expression
    public var end(default, null) : Int;

    public function new(reason: String, begin : Int, end : Int)
    {
        this.reason = reason;
        this.begin = begin;
        this.end = end;
    }
}


// This helper class handles parsing of Haxe expressions
private class ElementParser
{
    // This parser is implemented to parse the input string in reverse.  This
    // is a smaller and simpler implementation than a forward parser but it
    // does mean that some of the errors that it reports are less intuitive.
    public static function parse(str : String, beginColumn : Int) : ElementEnum
    {
        // Look for the last of "\"", ".", "]", or ")"
        var endIndex = maxIndexOf(str, str.length - 1, "\".])");

        // If no index, then treat it as a path
        if (endIndex == -1) {
            var value = StringTools.trim(str);
            var endColumn = beginColumn + (str.length - 1);
            if (value.length == 0) {
                if (endColumn < beginColumn) {
                    endColumn = beginColumn;
                }
                throw new ElementException
                    ("Empty value", beginColumn, endColumn);
            }
            return ElementEnum.Path(value, beginColumn, endColumn);
        }

        switch (str.charAt(endIndex)) {
        case "\"":
            var beginIndex = findBeginQuote(str, endIndex - 1);
            if (beginIndex == -1) {
                throw new ElementException
                    ("Mismatched quotes", beginColumn + endIndex,
                     beginColumn + (str.length - 1));
            }
            if (StringTools.trim(str.substring(0, beginIndex)).length > 0) {
                throw new ElementException
                    ("Unexpected value before quotes",
                     beginColumn, beginColumn + beginIndex);
            }
            return ElementEnum.Value
                (str.substring(beginIndex, endIndex + 1),
                 beginColumn + beginIndex, beginColumn + endIndex);
        case ".":
            // Check to see if it's a floating point value
            if (gFloatRegex.match(str)) {
                // Is it a valid float?
                if ((gFloatRegex.matched(2).length == 0) &&
                    (gFloatRegex.matched(3).length == 0)) {
                    throw new ElementException
                        ("Invalid value", beginColumn,
                         beginColumn + (str.length - 1));
                }
                // Yes, it's a valid floating point value
                return ElementEnum.Value(StringTools.trim(str), beginColumn,
                                         beginColumn + (str.length - 1));
            }
            // Ensure that there is something after the .
            var field = StringTools.trim(str.substring(endIndex + 1));
            if (field.length == 0) {
                throw new ElementException
                    ("Missing field", beginColumn + endIndex,
                     beginColumn + endIndex);
            }
            // Ensure that there is something before the .
            var pre = StringTools.trim(str.substring(0, endIndex));
            if (pre.length == 0) {
                throw new ElementException
                    ("Missing value", beginColumn, beginColumn + endIndex);
            }
            // Check for a special debugger construct
            if (pre == "$") {
                return ElementEnum.DebuggerField
                    (field, 0, (str.length - 1));
            }
            // Check to see if it's a path.  This can only occur at the
            // very beginning of the string
            if (beginColumn == 0) {
                // that allows for a local value storage pool
                if (gPathRegex.match(str)) {
                    // OK, this is at the very beginning of the input string
                    // and should be represented as a Path.  Check to ensure
                    // that it is a valid path.
                    return ElementEnum.Path
                        (StringTools.trim(str), 0, str.length - 1);
                }
            }
            // Else, it's not a path, it's a normal field reference
            if (gFieldRegex.match(field)) {
                var element = parse(str.substring(0, endIndex), beginColumn);
                return ElementEnum.Field(element, field, beginColumn,
                                         beginColumn + (str.length - 1));
            }
            else {
                throw new ElementException
                    ("Invalid field name", beginColumn + endIndex + 1,
                     beginColumn + (str.length - 1));
            }
        case "]":
            var beginIndex = levelPreviousIndexOf
                (str, endIndex - 1, "[", beginColumn);
            if (beginIndex == -1) {
                throw new ElementException
                    ("Mismatched array end", beginColumn,
                     beginColumn + endIndex);
            }
            if (StringTools.trim(str.substring(endIndex + 1)).length > 0) {
                throw new ElementException
                    ("Unexpected value after array index",
                     beginColumn + endIndex + 1,
                     beginColumn + (str.length - 1));
            }
            // If there is nothing before the open bracket, then this is
            // an array
            if (StringTools.trim(str.substring(0, beginIndex)).length == 0) {
                var array = parseList
                    (str.substring(beginIndex + 1, endIndex),
                     beginColumn + beginIndex + 1);
                return ElementEnum.Array_Value(array);
            }
            // Else it's an array dereference
            else {
                var element = parse(str.substring(0, beginIndex), beginColumn);
                var index = parse(str.substring(beginIndex + 1,
                                                endIndex), beginColumn);
                return ElementEnum.Array_Element(element, index);
            }
        default: // ")"
            var beginIndex = levelPreviousIndexOf
                (str, endIndex - 1, "(", beginColumn);
            if (beginIndex == -1) {
                throw new ElementException
                    ("Mismatched function parameters begin", beginColumn,
                     beginColumn + endIndex);
            }
            if (StringTools.trim(str.substring(endIndex + 1)).length > 0) {
                throw new ElementException
                    ("Unexpected value after function call",
                     beginColumn + endIndex + 1,
                     beginColumn + (str.length - 1));
            }
            var parameters = parseList(str.substring(beginIndex + 1,
                                                            endIndex),
                                              beginColumn + beginIndex + 1);
            var value = StringTools.trim(str.substring(0, beginIndex));
            if (StringTools.startsWith(value, "new ")) {
                if (value.length < 5) {
                    throw new ElementException
                        ("Invalid constructor call", 0, beginIndex);
                }
                return ElementEnum.Constructor_Call
                    (value.substring(4), parameters, beginColumn,
                     beginColumn + beginIndex);
            }
            else {
                var element = parse(value, beginColumn);
                return ElementEnum.Function_Call(element, parameters);
            }
        }
    }

    private static function parseList(str : String,
                                      beginColumn : Int) : Array<ElementEnum>
    {
        var ret = new Array<ElementEnum>();

        var index = str.length - 1;

        while (index >= 0) {
            var current : String;
            var commaIndex = levelPreviousIndexOf(str, index, ",", beginColumn);
            if (commaIndex == -1) {
                current = StringTools.trim(str);
                if (current.length == 0) {
                    return ret;
                }
                str = "";
            }
            else if (commaIndex == 0) {
                throw new ElementException
                    ("Missing array element", beginColumn,
                     beginColumn + commaIndex);
            }
            else {
                current = StringTools.trim(str.substring(commaIndex + 1));
                if (current.length == 0) {
                    throw new ElementException
                        ("Missing array element", beginColumn + commaIndex + 1,
                         beginColumn + commaIndex + 1);
                }
                str = str.substring(0, commaIndex);
            }

            ret.unshift(parse(current, beginColumn));
        }

        return ret;
    }

    private static function maxIndexOf(str : String, index : Int,
                                       find : String) : Int
    {
        while (index >= 0) {
            var c = str.charAt(index);
            for (f in 0...find.length) {
                if (c == find.charAt(f)) {
                    return index;
                }
            }
            index -= 1;
        }
        return -1;
    }

    private static function findBeginQuote(str : String, index : Int) : Int
    {
        while (index >= 0) {
            var quoteIndex = str.lastIndexOf("\"", index);
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
                index = quoteIndex - 1;
            }
        }
        return -1;
    }

    private static function levelPreviousIndexOf(str : String, index : Int,
                                                 find : String,
                                                 beginColumn : Int) : Int
    {
        var bracketLevel = 0, parenLevel = 0;

        while (index >= 0) {
            var char = str.charAt(index);
            if ((char == find) && (bracketLevel == 0) && (parenLevel == 0)) {
                return index;
            }
            else if (char == "]") {
                bracketLevel += 1;
            }
            else if (char == "[") {
                bracketLevel -= 1;
            }
            else if (char == ")") {
                parenLevel += 1;
            }
            else if (char == "(") {
                parenLevel -= 1;
            }
            else if (char == "\"") {
                var beginQuote = findBeginQuote(str, index - 1);
                if (beginQuote == -1) {
                    throw new ElementException
                        ("Mismatched quotes", 0, beginColumn + index);
                }
                index = beginQuote;
            }
            index -= 1;
        }

        return -1;
    }

    private static var gFieldRegex = ~/^[\s]*([a-zA-Z_][a-zA-Z0-9_]*)[\s]*$/;
    private static var gPathRegex =
    ~/^[\s]*[a-zA-Z_][a-zA-Z0-9_]*([\s]*\.[\s]*[a-zA-Z_][a-zA-Z0-9_]*)*[\s]*$/;
    private static var gFloatRegex = ~/^[\s]*(-)?([0-9]*)\.([0-9]*)[\s]*$/;
}
