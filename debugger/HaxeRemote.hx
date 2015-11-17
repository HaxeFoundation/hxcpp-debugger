/** **************************************************************************
 * HaxeRemote.hx
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

import debugger.HaxeProtocol;
import debugger.IController;

#if cpp
import cpp.vm.Thread;
import cpp.vm.Mutex;
import cpp.vm.Debugger;
#else
#error "HaxeRemote supported only for cpp targets"
#end


/**
 * This class creates a networked command-line debugger that communicates with
 * a peer using Haxe serialization format.  This class should be instantiated
 * int the main() function of any program that wishes to be debugged via a
 * remote interface.
 **/
class HaxeRemote implements IController
{
    /**
     * Creates a debugger which will read input from the interface provided
     * by the given remote host, and emit output to that remote host.
     *
     * If the program was not compiled with debugging support, a String
     * exception is thrown.
     *
     * @param startStopped if true, when the breakpoint starts, all other
     *        threads of the process are stopped until the user instructs the
     *        debugger to continue those threads.  If false, all threads of
     *        the program will continue to run when the debugger is started
     *        and will not stop until a debugger command instructs them to do
     *        so.
     * @param host is the host name of the debugging server to connect to
     * @param port is the port of the debugging server to connect to
     **/
    public function new(startStopped : Bool, host : String, port : Int = 6972)
    {
        LogDebuggerMessage("Starting App side debugger support.");

        mHost = host;
        mPort = port;
        mSocket = null;

        // Connect here.  We won't reconnect if there is a socket error.
        connect();

        // Spin up the write thread *before* the debugger thread.  Otherwise,
        // getNextCommand and acceptMessage are called before the write
        // thread is ready to queue messages.
        mWriteThread = Thread.create(function() {this.writeThreadLoop();});

        mThread = new DebuggerThread(this, startStopped);
    }

    private function closeSocket() {
        if (mSocket != null) {
            mSocket.close();
            mSocket = null;
        }
    }

    public function getNextCommand() : Command
    {
        while (true) {
            try {
                return HaxeProtocol.readCommand(mSocket.input);
            }
            catch (e : Dynamic) {
                LogDebuggerMessage("Failed to read command from server at " +
                            mHost + ":" + mPort + ": " + e);
                closeSocket();
                throw("Debugger Failure: Error reading socket: " + e);
            }
        }
    }

    /**
     * Called when the debugger has a message to deliver.  Note that this may
     * be called by multiple threads simultaneously if an asynchronous thread
     * event occurs.  The implementation should probably lock as necessary.
     *
     * @param message is the message
     **/
    public function acceptMessage(message : Message) : Void
    {
        // We actually write on a separate thread because the write is
        // blocking.  If we wait on such a write, and the other side of the
        // socket is also trying to write, then we deadlock.

        try {
            mWriteThread.sendMessage(message);
        }
        catch(msg : String) {
            var outmsg = "Failure sending message to debugger write thread:"
                            + msg;
            LogDebuggerMessage(outmsg);
            closeSocket();
            throw(outmsg);
        }
    }

    private function writeThreadLoop() : Void
    {
        // Have to turn off debugging on this thread, or else it stops, too.
        Debugger.enableCurrentThreadDebugging(false);

        try {
            var message : Message;
            while (true) {
                // Get the next message to write.  Block until there is
                // something to do.
                message = Thread.readMessage(true);
                HaxeProtocol.writeMessage(mSocket.output, message);
            }
        }
        catch (msg : String ) {
            var errmsg = "An error occurred on the write thread loop " +
                         "(sending messages to the debugger): " + msg;
            LogDebuggerMessage(errmsg);
            LogDebuggerMessage("Closing connection.");
            closeSocket();
            mWriteThread = null;
            // Throwing from here will (should!) finish the thread off.
            throw(errmsg);
        }
    }

    private function connect()
    {
        var socket : sys.net.Socket = new sys.net.Socket();

        while (true) {
            try {
                var host = new sys.net.Host(mHost);
                if (host.ip == 0) {
                    throw "Name lookup error.";
                }
                socket.connect(host, mPort);
                HaxeProtocol.writeClientIdentification(socket.output);
                HaxeProtocol.readServerIdentification(socket.input);
                LogDebuggerMessage("Connected to debugging server at " +
                            mHost + ":" + mPort + ".");

                mSocket = socket;
                return;
            }
            catch (e : Dynamic) {
                LogDebuggerMessage("Failed to connect to debugging server at " +
                            mHost + ":" + mPort + " : " + e);
            }
            LogDebuggerMessage("Trying again in 3 seconds.");
            Sys.sleep(3);
        }
    }

    private static function LogDebuggerMessage(message : String) {
        Sys.println("Debugger:" + message);
    }
    
    private var mHost : String;
    private var mPort : Int;
    private var mSocket : sys.net.Socket;
    private var mThread : DebuggerThread;
    private var mWriteThread : Thread;
}
