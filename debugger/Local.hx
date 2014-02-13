/** **************************************************************************
 * Local.hx
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


/**
 * This class creates a local command-line debugger.  This class should be
 * instantiated in the main() function of any program that wishes to be
 * debugged via the local command line.
 **/
class Local
{
    /**
     * Creates a debugger which will read input from the command line and
     * emit output to the terminal.
     *
     * If the program was not compiled with debugging support, a String
     * exception is thrown.
     *
     * @param startStopped if true, when the debugger starts, all other
     *        threads of the process are stopped until the user instructs the
     *        debugger to continue those threads.  If false, all threads of
     *        the program will continue to run when the debugger is started
     *        and will not stop until a debugger command instructs them to do
     *        so.
     **/
    public function new(startStopped : Bool)
    {
        mController = new CommandLineController();
        mThread = new DebuggerThread(mController, startStopped);
    }

    private var mController : CommandLineController;
    private var mThread : DebuggerThread;
}
