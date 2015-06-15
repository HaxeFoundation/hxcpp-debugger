/** **************************************************************************
 * HaxeProtocol.hx
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
 * This is a helper utility class that handles all message formatting for the
 * haxe serialization based remote debugger protocol.
 **/
class HaxeProtocol
{
    public static function writeClientIdentification(output : haxe.io.Output)
    {
        output.writeString(gClientIdentification);
    }

    public static function writeServerIdentification(output : haxe.io.Output)
    {
        output.writeString(gServerIdentification);
    }
    
    public static function readClientIdentification(input : haxe.io.Input)
    {
        var id = input.read(gClientIdentification.length);
        if (id.toString() != gClientIdentification) {
            throw "Unexpected client identification string: " + id;
        }
    }

    public static function readServerIdentification(input : haxe.io.Input)
    {
        var id = input.read(gServerIdentification.length);
        if (id.toString() != gServerIdentification) {
            throw "Unexpected server identification string: " + id;
        }
    }

    public static function writeCommand(output : haxe.io.Output,
                                        command : Command)
    {
        writeDynamic(output, command);
    }

    public static function writeMessage(output : haxe.io.Output,
                                        message : Message)
    {
        writeDynamic(output, message);
    }
    
    public static function readCommand(input : haxe.io.Input) : Command
    {
        var raw : Dynamic = readDynamic(input);

        // Convert to command and return
        try {
            return cast(raw, Command);
        }
        catch (e : Dynamic) {
            throw "Expected Command, but got " + raw + ": " + e;
        }
    }

    public static function readMessage(input : haxe.io.Input) : Message
    {
        var raw : Dynamic = readDynamic(input);

        // Convert to command and return
        try {
            return cast(raw, Message);
        }
        catch (e : Dynamic) {
            throw "Expected Message, but got " + raw + ": " + e;
        }
    }

    private static function writeDynamic(output : haxe.io.Output,
                                         value : Dynamic)
    {
        // Serialize it
        var string = haxe.Serializer.run(value);

        // Write its length
        var msg_len = string.length;
        var msg_len_raw = haxe.io.Bytes.alloc(8);

        for (i in 0 ... 8) {
            msg_len_raw.set(7 - i, (msg_len % 10) + 48);
            msg_len = Std.int(msg_len / 10);
        }

        output.write(msg_len_raw);
        output.writeString(string);
    }

    private static function readDynamic(input : haxe.io.Input) : Dynamic
    {
        var msg_len_raw = input.read(8);

        // Convert to number
        var msg_len : Int = 0;
        for (i in 0 ... 8) {
            msg_len *= 10;
            msg_len += msg_len_raw.get(i) - 48; // 48 is ASCII '0'
        }
        
        // Validate the length.  Don't allow messages larger than
        // 2 MB.
        if (msg_len > (2 * 1024 * 1024)) {
            throw "Read bad message length: " + msg_len + ".";
        }
        
        // Read and deserialize message
        return haxe.Unserializer.run(input.read(msg_len).toString());
    }

    private static var gClientIdentification = 
        "Haxe debug client v1.1 coming at you!\n\n";
    private static var gServerIdentification = 
        "Haxe debug server v1.1 ready and willing, sir!\n\n";
}
