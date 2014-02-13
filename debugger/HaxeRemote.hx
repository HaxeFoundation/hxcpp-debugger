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
import cpp.vm.Mutex;
#elseif neko
import neko.vm.Mutex;
#else
#error "HaxeRemote supported only for cpp and neko targets"
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
        mHost = host;
        mPort = port;
        mSocket = null;
        mSocketMutex = new Mutex();
        mAcceptMutex = new Mutex();
        mThread = new DebuggerThread(this, startStopped);
    }

    public function getNextCommand() : Command
    {
        while (true) {
            var socket;
            mSocketMutex.acquire();
            if (mSocket == null) {
                this.connectLocked();
            }
            socket = mSocket;
            mSocketMutex.release();
            try {
                return HaxeProtocol.readCommand(socket.input);
            }
            catch (e : Dynamic) {
                Sys.println("Failed to read command from server at " + 
                            mHost + ":" + mPort + ": " + e);
                Sys.println("Closing connection and trying again.");
                socket.close();
                mSocketMutex.acquire();
                if (mSocket == socket) {
                    mSocket = null;
                }
                mSocketMutex.release();
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
        while (true) {
            var socket;
            mSocketMutex.acquire();
            if (mSocket == null) {
                this.connectLocked();
            }
            socket = mSocket;
            mSocketMutex.release();
            mAcceptMutex.acquire();
            try {
                HaxeProtocol.writeMessage(socket.output, message);
                mAcceptMutex.release();
                return;
            }
            catch (e : Dynamic) {
                mAcceptMutex.release();
                Sys.println("Failed to deliver message to server at " + 
                            mHost + ":" + mPort + ": " + e);
                Sys.println("Closing connection and trying again.");
                socket.close();
                mSocketMutex.acquire();
                if (mSocket == socket) {
                    mSocket = null;
                }
                mSocketMutex.release();
            }
        }
    }

    private function connectLocked()
    {
        mSocket = new sys.net.Socket();
        while (true) {
            try {
                var host = new sys.net.Host(mHost);
                if (host.ip == 0) {
                    throw "Name lookup error.";
                }
                mSocket.connect(host, mPort);
                HaxeProtocol.writeClientIdentification(mSocket.output);
                HaxeProtocol.readServerIdentification(mSocket.input);
                Sys.println("Connected to debugging server at " + 
                            mHost + ":" + mPort + ".");
                return;
            }
            catch (e : Dynamic) {
                Sys.println("Failed to connect to debugging server at " +
                            mHost + ":" + mPort + " : " + e);
            }
            Sys.println("Trying again in 3 seconds.");
            Sys.sleep(3);
        }
    }

    private var mHost : String;
    private var mPort : Int;
    private var mSocket : sys.net.Socket;
    private var mSocketMutex : Mutex;
    private var mAcceptMutex : Mutex;
    private var mThread : DebuggerThread;
}
