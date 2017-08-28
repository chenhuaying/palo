// Copyright (c) 2017, Baidu.com, Inc. All Rights Reserved

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

package com.baidu.palo.mysql;

import java.io.ByteArrayOutputStream;
import java.io.UnsupportedEncodingException;
import java.nio.ByteBuffer;

import com.baidu.palo.catalog.Column;
import com.baidu.palo.catalog.PrimitiveType;

import com.google.common.base.Strings;

// used for serialize memory data to byte stream of MySQL protocol
public class MysqlSerializer {
    private ByteArrayOutputStream out;
    private MysqlCapability capability;

    public MysqlSerializer(ByteArrayOutputStream out) {
        this(out, MysqlCapability.DEFAULT_CAPABILITY);
    }

    public MysqlSerializer(ByteArrayOutputStream out, MysqlCapability capability) {
        this.out = out;
        this.capability = capability;
    }

    public static MysqlSerializer newInstance() {
        return new MysqlSerializer(new ByteArrayOutputStream());
    }

    public static MysqlSerializer newInstance(MysqlCapability capability) {
        return new MysqlSerializer(new ByteArrayOutputStream(), capability);
    }

    // used after success handshake
    public void setCapability(MysqlCapability capability) {
        this.capability = capability;
    }

    public MysqlCapability getCapability() {
        return capability;
    }

    public void writeByte(byte value) {
        out.write(value);
    }

    public void writeNull() {
        writeByte((byte) (251 & 0xff));
    }

    public void writeBytes(byte[] value, int offset, int length) {
        out.write(value, offset, length);
    }

    public void reset() {
        out.reset();
    }

    public byte[] toArray() {
        return out.toByteArray();
    }

    public ByteBuffer toByteBuffer() {
        return ByteBuffer.wrap(out.toByteArray());
    }

    public void writeBytes(byte[] value) {
        writeBytes(value, 0, value.length);
    }

    public void writeInt1(int value) {
        writeByte((byte) (value & 0XFF));
    }

    public void writeInt2(int value) {
        writeByte((byte) value);
        writeByte((byte) (value >> 8));
    }

    public void writeInt3(int value) {
        writeByte((byte) value);
        writeByte((byte) (value >> 8));
        writeByte((byte) (value >> 16));
    }

    public void writeInt4(int value) {
        writeByte((byte) value);
        writeByte((byte) (value >> 8));
        writeByte((byte) (value >> 16));
        writeByte((byte) (value >> 24));
    }

    public void writeInt6(long value) {
        writeInt4((int) value);
        writeInt2((byte) (value >> 32));
    }

    public void writeInt8(long value) {
        writeInt4((int) value);
        writeInt4((int) (value >> 32));
    }

    public void writeVInt(long value) {
        if (value < 251) {
            writeByte((byte) value);
        } else if (value < 0x10000) {
            writeInt1(252);
            writeInt2((int) value);
        } else if (value < 0x1000000) {
            writeInt1(253);
            writeInt3((int) value);
        } else {
            writeInt1(254);
            writeInt8(value);
        }
    }

    public void writeLenEncodedString(String value) {
        try {
            byte[] buf = value.getBytes("UTF-8");
            writeVInt(buf.length);
            writeBytes(buf);
        } catch (UnsupportedEncodingException e) {
            e.printStackTrace();
        }
    }

    public void writeEofString(String value) {
        try {
            byte[] buf = value.getBytes("UTF-8");
            writeBytes(buf);
        } catch (UnsupportedEncodingException e) {
            e.printStackTrace();
        }
    }

    public void writeNulTerminateString(String value) {
        try {
            byte[] buf = value.getBytes("UTF-8");
            writeBytes(buf);
            writeByte((byte) 0);
        } catch (UnsupportedEncodingException e) {
            e.printStackTrace();
        }
    }

    public void writeField(String db, String table, Column column, boolean sendDefault) {
        // Catalog Name: length encoded string
        writeLenEncodedString("def");
        // Schema: length encoded string
        writeLenEncodedString(db);
        // Table: length encoded string
        writeLenEncodedString(table);
        // Origin Table: length encoded string
        writeLenEncodedString(table);
        // Name: length encoded string
        writeLenEncodedString(column.getName());
        // Orignal Name: length encoded string
        writeLenEncodedString(column.getName());
        // length of the following fields(always 0x0c)
        writeVInt(0x0c);
        // Character set: two byte integer
        writeInt2(33);
        // TODO(zhaochun): fix Column length: four byte integer
        writeInt4(255);
        // Column type: one byte integer
        writeInt1(column.getDataType().toMysqlType().getCode());
        // Flags: two byte integer
        writeInt2(0);
        // Decimals: one byte integer
        writeInt1(0);
        // filler: two byte integer
        writeInt2(0);

        if (sendDefault) {
            // Sending default value.
            writeLenEncodedString(Strings.nullToEmpty(column.getDefaultValue()));
        }
    }

    // Format field with name and type.
    public void writeField(String colName, PrimitiveType type) {
        // Catalog Name: length encoded string
        writeLenEncodedString("def");
        // Schema: length encoded string
        writeLenEncodedString("");
        // Table: length encoded string
        writeLenEncodedString("");
        // Origin Table: length encoded string
        writeLenEncodedString("");
        // Name: length encoded string
        writeLenEncodedString(colName);
        // Orignal Name: length encoded string
        writeLenEncodedString(colName);
        // length of the following fields(always 0x0c)
        writeVInt(0x0c);
        // Character set: two byte integer
        writeInt2(33);
        // Column length: four byte integer
        writeInt4(255);
        // Column type: one byte integer
        writeInt1(type.toMysqlType().getCode());
        // Flags: two byte integer
        writeInt2(0);
        // Decimals: one byte integer
        writeInt1(0);
        // filler: two byte integer
        writeInt2(0);
    }
}
