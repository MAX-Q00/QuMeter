// QuSnmp.cs — SNMPv1/v2c over UDP for QuMeter / QuMeter Auto.
// C# 5 compatible (Windows PowerShell 5.1 Add-Type).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace QuMeterSnmp
{
    public enum SnmpVersion
    {
        V1 = 0,
        V2c = 1
    }

    public enum SnmpPduType
    {
        GetRequest = 0,
        GetNextRequest = 1,
        GetResponse = 2,
        SetRequest = 3,
        GetBulkRequest = 5
    }

    public class SnmpValue
    {
        public string Oid;
        public string TypeName;
        public byte Tag;
        public byte[] Raw;
        public object Value;
        public string Error; // noSuchObject / noSuchInstance / endOfMibView

        public bool IsError
        {
            get { return !string.IsNullOrEmpty(this.Error); }
        }

        public override string ToString()
        {
            if (this.IsError) return this.Error;
            if (this.Value == null) return "";
            return Convert.ToString(this.Value, CultureInfo.InvariantCulture);
        }
    }

    public class SnmpResponse
    {
        public int RequestId;
        public int ErrorStatus;
        public int ErrorIndex;
        public string ErrorName;
        public List<SnmpValue> Variables;
        public byte[] Packet;

        public SnmpResponse()
        {
            this.Variables = new List<SnmpValue>();
        }

        public SnmpValue Find(string oid)
        {
            string n = Ber.NormalizeOid(oid);
            for (int i = 0; i < this.Variables.Count; i++)
            {
                if (Ber.NormalizeOid(this.Variables[i].Oid) == n) return this.Variables[i];
            }
            return null;
        }
    }

    public class PrinterReading
    {
        public string Ip;
        public string SysDescr = "";
        public string Model = "";
        public string Serial = "";
        public string Total = "";
        public string Mono = "";
        public string Color = "";
        public string Status = "";
        public string ErrorMessage = "";
        public string SerialSource = "";
        public string ModelSource = "";
        public string TotalSource = "";
        public DateTime ReadAt;

        public bool Ok
        {
            get { return this.Status == "OK"; }
        }
    }

    public static class Ber
    {
        public const byte TagSequence = 0x30;
        public const byte TagInteger = 0x02;
        public const byte TagOctetString = 0x04;
        public const byte TagNull = 0x05;
        public const byte TagOid = 0x06;
        public const byte TagIpAddress = 0x40;
        public const byte TagCounter32 = 0x41;
        public const byte TagGauge32 = 0x42;
        public const byte TagTimeTicks = 0x43;
        public const byte TagOpaque = 0x44;
        public const byte TagCounter64 = 0x46;
        public const byte TagNoSuchObject = 0x80;
        public const byte TagNoSuchInstance = 0x81;
        public const byte TagEndOfMibView = 0x82;
        public const byte TagGetRequest = 0xA0;
        public const byte TagGetNextRequest = 0xA1;
        public const byte TagGetResponse = 0xA2;
        public const byte TagGetBulkRequest = 0xA5;

        public static string NormalizeOid(string oid)
        {
            if (oid == null) return "";
            return oid.Trim().TrimStart('.');
        }

        public static byte[] EncodeLength(int length)
        {
            if (length < 0) throw new ArgumentOutOfRangeException("length");
            if (length < 128) return new byte[] { (byte)length };
            byte[] tmp = new byte[4];
            int n = 0;
            uint u = (uint)length;
            for (int i = 3; i >= 0; i--)
            {
                byte b = (byte)((u >> (8 * i)) & 0xFF);
                if (n == 0 && b == 0) continue;
                tmp[n++] = b;
            }
            if (n == 0) { tmp[0] = 0; n = 1; }
            byte[] result = new byte[1 + n];
            result[0] = (byte)(0x80 | n);
            Array.Copy(tmp, 0, result, 1, n);
            return result;
        }

        public static byte[] EncodeTlv(byte tag, byte[] value)
        {
            if (value == null) value = new byte[0];
            byte[] len = EncodeLength(value.Length);
            byte[] r = new byte[1 + len.Length + value.Length];
            r[0] = tag;
            Array.Copy(len, 0, r, 1, len.Length);
            Array.Copy(value, 0, r, 1 + len.Length, value.Length);
            return r;
        }

        public static byte[] EncodeNull()
        {
            return new byte[] { TagNull, 0x00 };
        }

        public static byte[] EncodeInteger(long value)
        {
            return EncodeTlv(TagInteger, IntegerBytes(value, false));
        }

        public static byte[] EncodeUnsigned(byte tag, ulong value)
        {
            return EncodeTlv(tag, IntegerBytes(value));
        }

        public static byte[] EncodeOctetString(byte[] data)
        {
            return EncodeTlv(TagOctetString, data == null ? new byte[0] : data);
        }

        public static byte[] EncodeOctetString(string s)
        {
            return EncodeOctetString(s == null ? new byte[0] : Encoding.ASCII.GetBytes(s));
        }

        public static byte[] EncodeOid(string oid)
        {
            string n = NormalizeOid(oid);
            string[] parts = n.Split('.');
            if (parts.Length < 2) throw new ArgumentException("OID must have at least two arcs: " + oid);
            uint[] arcs = new uint[parts.Length];
            for (int i = 0; i < parts.Length; i++)
            {
                uint arc;
                if (!uint.TryParse(parts[i], NumberStyles.Integer, CultureInfo.InvariantCulture, out arc))
                    throw new ArgumentException("Invalid OID arc: " + parts[i]);
                arcs[i] = arc;
            }
            if (arcs[0] > 2) throw new ArgumentException("First OID arc must be 0..2");
            if (arcs[0] < 2 && arcs[1] > 39) throw new ArgumentException("Second OID arc too large");
            MemoryStream ms = new MemoryStream();
            ms.WriteByte((byte)(arcs[0] * 40 + arcs[1]));
            for (int i = 2; i < arcs.Length; i++) WriteSubIdentifier(ms, arcs[i]);
            return EncodeTlv(TagOid, ms.ToArray());
        }

        public static void WriteSubIdentifier(Stream ms, uint value)
        {
            if (value < 128)
            {
                ms.WriteByte((byte)value);
                return;
            }
            byte[] buf = new byte[5];
            int n = 0;
            uint v = value;
            buf[n++] = (byte)(v & 0x7F);
            v >>= 7;
            while (v > 0)
            {
                buf[n++] = (byte)((v & 0x7F) | 0x80);
                v >>= 7;
            }
            for (int i = n - 1; i >= 0; i--) ms.WriteByte(buf[i]);
        }

        public static byte[] IntegerBytes(long value, bool unused)
        {
            // Two's complement, shortest BER integer (no leading 00/FF except to preserve sign).
            byte[] full = new byte[8];
            for (int i = 0; i < 8; i++) full[i] = (byte)((value >> (56 - 8 * i)) & 0xFF);
            int start = 0;
            while (start < 7)
            {
                if (full[start] == 0x00 && (full[start + 1] & 0x80) == 0) { start++; continue; }
                if (full[start] == 0xFF && (full[start + 1] & 0x80) != 0) { start++; continue; }
                break;
            }
            byte[] r = new byte[8 - start];
            Array.Copy(full, start, r, 0, r.Length);
            return r;
        }

        public static byte[] IntegerBytes(ulong value)
        {
            byte[] full = new byte[9];
            full[0] = 0x00;
            for (int i = 0; i < 8; i++) full[i + 1] = (byte)((value >> (56 - 8 * i)) & 0xFF);
            int start = 0;
            while (start < 8)
            {
                if (full[start] == 0x00 && (full[start + 1] & 0x80) == 0) { start++; continue; }
                break;
            }
            byte[] r = new byte[9 - start];
            Array.Copy(full, start, r, 0, r.Length);
            return r;
        }

        public static string DecodeOid(byte[] data)
        {
            if (data == null || data.Length == 0) throw new InvalidDataException("Empty OID");
            List<uint> arcs = new List<uint>();
            byte first = data[0];
            arcs.Add((uint)(first / 40));
            arcs.Add((uint)(first % 40));
            // first arc 2 can have second > 39 (encoded as 80+), already handled by % 40 only when first/40==2 and first>=120...
            // Standard: if first >= 80, first arc is 2 and second is first-80.
            if (first >= 80)
            {
                arcs[0] = 2;
                arcs[1] = (uint)(first - 80);
            }
            int i = 1;
            while (i < data.Length)
            {
                ulong v = 0;
                int guard = 0;
                while (i < data.Length)
                {
                    byte b = data[i++];
                    v = (v << 7) | (byte)(b & 0x7F);
                    guard++;
                    if (guard > 5) throw new InvalidDataException("OID sub-identifier too long");
                    if ((b & 0x80) == 0) break;
                    if (i >= data.Length) throw new InvalidDataException("Truncated OID sub-identifier");
                }
                if (v > uint.MaxValue) throw new InvalidDataException("OID sub-identifier overflow");
                arcs.Add((uint)v);
            }
            StringBuilder sb = new StringBuilder();
            for (int a = 0; a < arcs.Count; a++)
            {
                if (a > 0) sb.Append('.');
                sb.Append(arcs[a].ToString(CultureInfo.InvariantCulture));
            }
            return sb.ToString();
        }

        public static long DecodeSignedInteger(byte[] data)
        {
            if (data == null || data.Length == 0) throw new InvalidDataException("Empty integer");
            if (data.Length > 8) throw new InvalidDataException("Integer too long");
            long v = (data[0] & 0x80) != 0 ? -1 : 0;
            for (int i = 0; i < data.Length; i++) v = (v << 8) | data[i];
            return v;
        }

        public static ulong DecodeUnsignedInteger(byte[] data)
        {
            if (data == null || data.Length == 0) throw new InvalidDataException("Empty integer");
            if (data.Length > 9) throw new InvalidDataException("Unsigned integer too long");
            if (data.Length == 9 && data[0] != 0) throw new InvalidDataException("Unsigned integer overflow");
            ulong v = 0;
            for (int i = 0; i < data.Length; i++) v = (v << 8) | data[i];
            return v;
        }

        public static Tlv ReadTlv(byte[] buf, ref int pos)
        {
            if (pos >= buf.Length) throw new InvalidDataException("Unexpected end of BER data");
            Tlv t = new Tlv();
            t.Tag = buf[pos++];
            if (pos >= buf.Length) throw new InvalidDataException("Missing BER length");
            int lenByte = buf[pos++];
            int length;
            if ((lenByte & 0x80) == 0)
            {
                length = lenByte;
            }
            else
            {
                int nbytes = lenByte & 0x7F;
                if (nbytes == 0) throw new InvalidDataException("Indefinite BER length is not supported");
                if (nbytes > 4) throw new InvalidDataException("BER length too large");
                if (pos + nbytes > buf.Length) throw new InvalidDataException("Truncated BER length");
                length = 0;
                for (int i = 0; i < nbytes; i++) length = (length << 8) | buf[pos++];
            }
            if (length < 0 || pos + length > buf.Length) throw new InvalidDataException("Truncated BER value");
            t.Value = new byte[length];
            Array.Copy(buf, pos, t.Value, 0, length);
            pos += length;
            return t;
        }

        public class Tlv
        {
            public byte Tag;
            public byte[] Value;
        }

        public static SnmpValue DecodeSnmpValue(Tlv t)
        {
            SnmpValue v = new SnmpValue();
            v.Tag = t.Tag;
            v.Raw = t.Value;
            switch (t.Tag)
            {
                case TagInteger:
                    v.TypeName = "INTEGER";
                    v.Value = DecodeSignedInteger(t.Value);
                    break;
                case TagOctetString:
                    v.TypeName = "OCTET STRING";
                    v.Value = t.Value;
                    break;
                case TagNull:
                    v.TypeName = "NULL";
                    v.Value = null;
                    break;
                case TagOid:
                    v.TypeName = "OBJECT IDENTIFIER";
                    v.Value = DecodeOid(t.Value);
                    break;
                case TagIpAddress:
                    v.TypeName = "IpAddress";
                    v.Value = t.Value;
                    break;
                case TagCounter32:
                    v.TypeName = "Counter32";
                    v.Value = DecodeUnsignedInteger(t.Value);
                    break;
                case TagGauge32:
                    v.TypeName = "Gauge32";
                    v.Value = DecodeUnsignedInteger(t.Value);
                    break;
                case TagTimeTicks:
                    v.TypeName = "TimeTicks";
                    v.Value = DecodeUnsignedInteger(t.Value);
                    break;
                case TagOpaque:
                    v.TypeName = "Opaque";
                    v.Value = t.Value;
                    break;
                case TagCounter64:
                    v.TypeName = "Counter64";
                    v.Value = DecodeUnsignedInteger(t.Value);
                    break;
                case TagNoSuchObject:
                    v.TypeName = "noSuchObject";
                    v.Error = "noSuchObject";
                    break;
                case TagNoSuchInstance:
                    v.TypeName = "noSuchInstance";
                    v.Error = "noSuchInstance";
                    break;
                case TagEndOfMibView:
                    v.TypeName = "endOfMibView";
                    v.Error = "endOfMibView";
                    break;
                default:
                    v.TypeName = "tag-0x" + t.Tag.ToString("X2");
                    v.Value = t.Value;
                    break;
            }
            return v;
        }

        public static string ErrorStatusName(int status)
        {
            switch (status)
            {
                case 0: return "noError";
                case 1: return "tooBig";
                case 2: return "noSuchName";
                case 3: return "badValue";
                case 4: return "readOnly";
                case 5: return "genErr";
                case 6: return "noAccess";
                case 7: return "wrongType";
                case 8: return "wrongLength";
                case 9: return "wrongEncoding";
                case 10: return "wrongValue";
                case 11: return "noCreation";
                case 12: return "inconsistentValue";
                case 13: return "resourceUnavailable";
                case 14: return "commitFailed";
                case 15: return "undoFailed";
                case 16: return "authorizationError";
                case 17: return "notWritable";
                case 18: return "inconsistentName";
                default: return "error-" + status.ToString(CultureInfo.InvariantCulture);
            }
        }
    }

    public static class SnmpCodec
    {
        public static byte[] BuildRequest(SnmpVersion version, string community, SnmpPduType pdu, int requestId, IList<string> oids)
        {
            MemoryStream vars = new MemoryStream();
            for (int i = 0; i < oids.Count; i++)
            {
                byte[] oid = Ber.EncodeOid(oids[i]);
                byte[] nul = Ber.EncodeNull();
                byte[] bind = new byte[oid.Length + nul.Length];
                Array.Copy(oid, 0, bind, 0, oid.Length);
                Array.Copy(nul, 0, bind, oid.Length, nul.Length);
                byte[] seq = Ber.EncodeTlv(Ber.TagSequence, bind);
                vars.Write(seq, 0, seq.Length);
            }
            MemoryStream pduBody = new MemoryStream();
            WriteAll(pduBody, Ber.EncodeInteger(requestId));
            WriteAll(pduBody, Ber.EncodeInteger(0));
            WriteAll(pduBody, Ber.EncodeInteger(0));
            WriteAll(pduBody, Ber.EncodeTlv(Ber.TagSequence, vars.ToArray()));
            byte pduTag = (pdu == SnmpPduType.GetNextRequest) ? Ber.TagGetNextRequest : Ber.TagGetRequest;
            if (pdu == SnmpPduType.GetBulkRequest) pduTag = Ber.TagGetBulkRequest;
            byte[] pduBytes = Ber.EncodeTlv(pduTag, pduBody.ToArray());

            MemoryStream msg = new MemoryStream();
            WriteAll(msg, Ber.EncodeInteger((int)version));
            WriteAll(msg, Ber.EncodeOctetString(community ?? ""));
            WriteAll(msg, pduBytes);
            return Ber.EncodeTlv(Ber.TagSequence, msg.ToArray());
        }

        private static void WriteAll(Stream s, byte[] data)
        {
            s.Write(data, 0, data.Length);
        }

        public static SnmpResponse ParseResponse(byte[] packet)
        {
            if (packet == null || packet.Length == 0) throw new InvalidDataException("Empty SNMP packet");
            int pos = 0;
            Ber.Tlv msg = Ber.ReadTlv(packet, ref pos);
            if (msg.Tag != Ber.TagSequence) throw new InvalidDataException("SNMP message is not a SEQUENCE");
            int mpos = 0;
            Ber.Tlv ver = Ber.ReadTlv(msg.Value, ref mpos);
            Ber.Tlv community = Ber.ReadTlv(msg.Value, ref mpos);
            Ber.Tlv pdu = Ber.ReadTlv(msg.Value, ref mpos);
            if (pdu.Tag != Ber.TagGetResponse)
            {
                // Still try to parse the body so tests can inspect unexpected PDUs.
            }
            int ppos = 0;
            Ber.Tlv rid = Ber.ReadTlv(pdu.Value, ref ppos);
            Ber.Tlv err = Ber.ReadTlv(pdu.Value, ref ppos);
            Ber.Tlv eidx = Ber.ReadTlv(pdu.Value, ref ppos);
            Ber.Tlv vbl = Ber.ReadTlv(pdu.Value, ref ppos);
            if (vbl.Tag != Ber.TagSequence) throw new InvalidDataException("VarBind list is not a SEQUENCE");

            SnmpResponse r = new SnmpResponse();
            r.Packet = packet;
            r.RequestId = (int)Ber.DecodeSignedInteger(rid.Value);
            r.ErrorStatus = (int)Ber.DecodeSignedInteger(err.Value);
            r.ErrorIndex = (int)Ber.DecodeSignedInteger(eidx.Value);
            r.ErrorName = Ber.ErrorStatusName(r.ErrorStatus);

            int vpos = 0;
            while (vpos < vbl.Value.Length)
            {
                Ber.Tlv bind = Ber.ReadTlv(vbl.Value, ref vpos);
                if (bind.Tag != Ber.TagSequence) throw new InvalidDataException("VarBind is not a SEQUENCE");
                int bpos = 0;
                Ber.Tlv oidTlv = Ber.ReadTlv(bind.Value, ref bpos);
                Ber.Tlv valTlv = Ber.ReadTlv(bind.Value, ref bpos);
                SnmpValue sv = Ber.DecodeSnmpValue(valTlv);
                if (oidTlv.Tag != Ber.TagOid) throw new InvalidDataException("VarBind OID is not an OBJECT IDENTIFIER");
                sv.Oid = Ber.DecodeOid(oidTlv.Value);
                r.Variables.Add(sv);
            }
            return r;
        }
    }

    public class SnmpClient
    {
        private static int _nextId = Environment.TickCount;

        public string Community = "public";
        public int Port = 161;
        public int TimeoutMs = 1500;
        public int Retries = 1;
        public SnmpVersion Version = SnmpVersion.V2c;

        public static int NextRequestId()
        {
            int id = Interlocked.Increment(ref _nextId);
            if (id == int.MinValue || id == 0) id = Interlocked.Increment(ref _nextId);
            return id;
        }

        public SnmpResponse Get(string host, IList<string> oids)
        {
            return Request(host, SnmpPduType.GetRequest, oids);
        }

        public SnmpResponse GetNext(string host, IList<string> oids)
        {
            return Request(host, SnmpPduType.GetNextRequest, oids);
        }

        public SnmpResponse Get(string host, string oid)
        {
            return Get(host, new string[] { oid });
        }

        public SnmpResponse GetNext(string host, string oid)
        {
            return GetNext(host, new string[] { oid });
        }

        public List<SnmpValue> Walk(string host, string prefix, int maxSteps)
        {
            string root = Ber.NormalizeOid(prefix);
            List<SnmpValue> list = new List<SnmpValue>();
            string current = root;
            if (maxSteps <= 0) maxSteps = 64;
            for (int i = 0; i < maxSteps; i++)
            {
                SnmpResponse r = GetNext(host, current);
                if (r == null || r.Variables.Count == 0) break;
                SnmpValue v = r.Variables[0];
                if (v.IsError && v.Error == "endOfMibView") break;
                if (string.IsNullOrEmpty(v.Oid)) break;
                string n = Ber.NormalizeOid(v.Oid);
                if (n != root && !n.StartsWith(root + ".", StringComparison.Ordinal)) break;
                list.Add(v);
                current = n;
            }
            return list;
        }

        public SnmpResponse Request(string host, SnmpPduType pdu, IList<string> oids)
        {
            if (oids == null || oids.Count == 0) throw new ArgumentException("oids");
            int requestId = NextRequestId();
            byte[] packet = SnmpCodec.BuildRequest(this.Version, this.Community, pdu, requestId, oids);
            Exception last = null;
            int attempts = this.Retries + 1;
            if (attempts < 1) attempts = 1;
            for (int a = 0; a < attempts; a++)
            {
                try
                {
                    byte[] reply = UdpExchange(host, this.Port, packet, this.TimeoutMs);
                    SnmpResponse r = SnmpCodec.ParseResponse(reply);
                    return r;
                }
                catch (Exception ex)
                {
                    last = ex;
                }
            }
            throw new TimeoutException("SNMP timeout contacting " + host + ":" + this.Port.ToString(CultureInfo.InvariantCulture) + (last != null ? " (" + last.Message + ")" : ""));
        }

        public static byte[] UdpExchange(string host, int port, byte[] packet, int timeoutMs)
        {
            IPAddress[] addrs = Dns.GetHostAddresses(host);
            IPAddress ip = null;
            for (int i = 0; i < addrs.Length; i++)
            {
                if (addrs[i].AddressFamily == AddressFamily.InterNetwork)
                {
                    ip = addrs[i];
                    break;
                }
            }
            if (ip == null && addrs.Length > 0) ip = addrs[0];
            if (ip == null) throw new SocketException();

            UdpClient udp = new UdpClient();
            try
            {
                udp.Client.ReceiveTimeout = timeoutMs;
                udp.Client.SendTimeout = timeoutMs;
                IPEndPoint dest = new IPEndPoint(ip, port);
                udp.Send(packet, packet.Length, dest);
                IPEndPoint remote = new IPEndPoint(IPAddress.Any, 0);
                return udp.Receive(ref remote);
            }
            finally
            {
                udp.Close();
            }
        }
    }

    public static class Oids
    {
        // RFC 1213 / SNMPv2-MIB
        public const string SysDescr = "1.3.6.1.2.1.1.1.0";
        public const string SysName = "1.3.6.1.2.1.1.5.0";
        // HOST-RESOURCES-MIB
        public const string HrDeviceDescr = "1.3.6.1.2.1.25.3.2.1.3.1";
        public const string HrDeviceDescrPrefix = "1.3.6.1.2.1.25.3.2.1.3";
        // Printer-MIB (RFC 3805)
        public const string PrtGeneralPrinterName = "1.3.6.1.2.1.43.5.1.1.16.1";
        public const string PrtGeneralSerialNumber = "1.3.6.1.2.1.43.5.1.1.17.1";
        public const string PrtGeneralSerialPrefix = "1.3.6.1.2.1.43.5.1.1.17";
        public const string PrtMarkerLifeCount = "1.3.6.1.2.1.43.10.2.1.4.1.1";
        public const string PrtMarkerLifePrefix = "1.3.6.1.2.1.43.10.2.1.4";
        // HP-LASERJET-COMMON-MIB (enterprises.11 ... device)
        // serial-number ::= { id 3 }  id ::= { device-system 3 }  device-system ::= { device 1 }
        public const string HpSerialNumber = "1.3.6.1.4.1.11.2.3.9.4.2.1.1.3.3.0";
        public const string HpModelName = "1.3.6.1.4.1.11.2.3.9.4.2.1.1.3.2.0";
        public const string HpModelNumber = "1.3.6.1.4.1.11.2.3.9.4.2.1.1.3.1.0";
        // total-mono-page-count ::= { status-prt-eng 6 }
        public const string HpTotalMonoPageCount = "1.3.6.1.4.1.11.2.3.9.4.2.1.4.1.2.6.0";
        // total-color-page-count ::= { status-prt-eng 7 }
        public const string HpTotalColorPageCount = "1.3.6.1.4.1.11.2.3.9.4.2.1.4.1.2.7.0";
    }

    public static class ValueFormat
    {
        public static string StripHpSymbolSet(byte[] data)
        {
            if (data == null || data.Length == 0) return "";
            int start = 0;
            // HP-LASERJET-COMMON-MIB: first two bytes may be a symbol-set id (Roman-8 = 0x0115).
            if (data.Length >= 3 && data[0] <= 0x02 && !IsPrintableAscii(data[0]))
            {
                bool restPrintable = true;
                for (int i = 2; i < data.Length; i++)
                {
                    if (data[i] == 0) break;
                    if (!IsPrintableAscii(data[i]) && data[i] != 0x09 && data[i] != 0x0A && data[i] != 0x0D)
                    {
                        restPrintable = false;
                        break;
                    }
                }
                if (restPrintable) start = 2;
            }
            StringBuilder sb = new StringBuilder();
            for (int i = start; i < data.Length; i++)
            {
                if (data[i] == 0) break;
                if (data[i] >= 32 && data[i] < 127) sb.Append((char)data[i]);
                else if (data[i] == 0x09 || data[i] == 0x0A || data[i] == 0x0D) sb.Append(' ');
            }
            return sb.ToString().Trim();
        }

        public static bool IsPrintableAscii(byte b)
        {
            return b >= 32 && b < 127;
        }

        public static string AsDisplayString(SnmpValue v)
        {
            if (v == null || v.IsError) return "";
            if (v.Tag == Ber.TagOctetString || v.Tag == Ber.TagOpaque || v.Tag == Ber.TagIpAddress)
            {
                return StripHpSymbolSet(v.Raw);
            }
            if (v.Value == null) return "";
            return Convert.ToString(v.Value, CultureInfo.InvariantCulture).Trim();
        }

        public static string AsMeterCount(SnmpValue v)
        {
            if (v == null || v.IsError) return "";
            if (v.Tag == Ber.TagInteger || v.Tag == Ber.TagCounter32 || v.Tag == Ber.TagGauge32 ||
                v.Tag == Ber.TagCounter64 || v.Tag == Ber.TagTimeTicks)
            {
                if (v.Value == null) return "";
                return Convert.ToString(v.Value, CultureInfo.InvariantCulture);
            }
            if (v.Tag == Ber.TagOctetString)
            {
                string s = StripHpSymbolSet(v.Raw);
                if (IsAllDigits(s)) return s;
            }
            return "";
        }

        public static bool IsAllDigits(string s)
        {
            if (string.IsNullOrEmpty(s)) return false;
            for (int i = 0; i < s.Length; i++)
            {
                if (s[i] < '0' || s[i] > '9') return false;
            }
            return true;
        }
    }

    public static class TargetParser
    {
        public static List<string> Parse(string text, int maxAddresses)
        {
            List<string> list = new List<string>();
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (string.IsNullOrEmpty(text)) return list;
            string[] rawLines = text.Split(new char[] { '\r', '\n', ',', ';' }, StringSplitOptions.RemoveEmptyEntries);
            for (int i = 0; i < rawLines.Length; i++)
            {
                string line = rawLines[i].Trim();
                if (line.Length == 0) continue;
                if (line.StartsWith("//", StringComparison.Ordinal)) continue;
                int comment = line.IndexOf('#');
                if (comment >= 0) line = line.Substring(0, comment).Trim();
                if (line.Length == 0) continue;
                string[] tokens = line.Split(new char[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                for (int t = 0; t < tokens.Length; t++)
                {
                    List<string> expanded = ExpandToken(tokens[t]);
                    for (int j = 0; j < expanded.Count; j++)
                    {
                        if (seen.Add(expanded[j]))
                        {
                            if (maxAddresses > 0 && list.Count >= maxAddresses)
                                throw new ArgumentException("Target list expands to more than " + maxAddresses.ToString(CultureInfo.InvariantCulture) + " addresses.");
                            list.Add(expanded[j]);
                        }
                    }
                }
            }
            return list;
        }

        public static List<string> ExpandToken(string token)
        {
            List<string> list = new List<string>();
            token = token.Trim();
            int slash = token.IndexOf('/');
            if (slash > 0)
            {
                string ip = token.Substring(0, slash);
                string pfx = token.Substring(slash + 1);
                int prefix;
                IPAddress addr;
                if (IPAddress.TryParse(ip, out addr) && addr.AddressFamily == AddressFamily.InterNetwork &&
                    int.TryParse(pfx, NumberStyles.Integer, CultureInfo.InvariantCulture, out prefix) &&
                    prefix >= 0 && prefix <= 32)
                {
                    return ExpandCidr(addr, prefix);
                }
            }
            int dash = token.LastIndexOf('-');
            if (dash > 0)
            {
                string left = token.Substring(0, dash).Trim();
                string right = token.Substring(dash + 1).Trim();
                IPAddress a, b;
                if (IPAddress.TryParse(left, out a) && a.AddressFamily == AddressFamily.InterNetwork)
                {
                    // "10.0.0.1-10.0.0.5" (dotted end) vs "10.0.0.1-5" (last-octet end).
                    // Do not IP-parse a bare number: some runtimes accept "5" as 0.0.0.5.
                    if (right.IndexOf('.') >= 0)
                    {
                        if (IPAddress.TryParse(right, out b) && b.AddressFamily == AddressFamily.InterNetwork)
                        {
                            return ExpandRange(IpToUint(a), IpToUint(b));
                        }
                    }
                    else
                    {
                        int lastOctet;
                        if (int.TryParse(right, NumberStyles.Integer, CultureInfo.InvariantCulture, out lastOctet) &&
                            lastOctet >= 0 && lastOctet <= 255)
                        {
                            uint start = IpToUint(a);
                            uint end = (start & 0xFFFFFF00u) | (uint)lastOctet;
                            return ExpandRange(start, end);
                        }
                    }
                }
            }
            list.Add(token);
            return list;
        }

        public static List<string> ExpandCidr(IPAddress addr, int prefix)
        {
            uint start = IpToUint(addr);
            uint mask = prefix == 0 ? 0u : 0xFFFFFFFFu << (32 - prefix);
            start = start & mask;
            uint end = start | (uint)(~mask);
            return ExpandRange(start, end);
        }

        public static List<string> ExpandRange(uint start, uint end)
        {
            if (end < start)
            {
                uint t = start;
                start = end;
                end = t;
            }
            if (end - start > 65536) throw new ArgumentException("IP range is larger than 65536 addresses.");
            List<string> list = new List<string>();
            for (uint i = start; i <= end; i++)
            {
                list.Add(UintToIp(i));
                if (i == uint.MaxValue) break;
            }
            return list;
        }

        public static uint IpToUint(IPAddress addr)
        {
            byte[] b = addr.GetAddressBytes();
            return ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
        }

        public static string UintToIp(uint v)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0}.{1}.{2}.{3}",
                (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
        }

        public static int CountEstimate(string text)
        {
            // Used by the GUI to warn before a large scan. Does not cap.
            List<string> list = Parse(text, 65536);
            return list.Count;
        }
    }

    public static class PrinterQuery
    {
        public static PrinterReading Query(SnmpClient client, string host)
        {
            PrinterReading r = new PrinterReading();
            r.Ip = host;
            r.ReadAt = DateTime.Now;
            try
            {
                string[] first = new string[] {
                    Oids.SysDescr,
                    Oids.HrDeviceDescr,
                    Oids.PrtGeneralPrinterName,
                    Oids.PrtGeneralSerialNumber,
                    Oids.HpSerialNumber,
                    Oids.HpModelName,
                    Oids.PrtMarkerLifeCount,
                    Oids.HpTotalMonoPageCount,
                    Oids.HpTotalColorPageCount
                };

                SnmpResponse resp;
                if (client.Version == SnmpVersion.V1)
                {
                    resp = GetOneByOne(client, host, first);
                }
                else
                {
                    try
                    {
                        resp = client.Get(host, first);
                        if (resp.ErrorStatus != 0)
                        {
                            // v1-style devices sometimes error the whole PDU; fall back to one-by-one.
                            resp = GetOneByOne(client, host, first);
                        }
                    }
                    catch (TimeoutException)
                    {
                        throw;
                    }
                    catch
                    {
                        resp = GetOneByOne(client, host, first);
                    }
                }

                r.SysDescr = ValueFormat.AsDisplayString(resp.Find(Oids.SysDescr));

                string model = ValueFormat.AsDisplayString(resp.Find(Oids.HrDeviceDescr));
                if (!string.IsNullOrEmpty(model))
                {
                    r.Model = model;
                    r.ModelSource = "hrDeviceDescr";
                }
                else
                {
                    string hpModel = ValueFormat.AsDisplayString(resp.Find(Oids.HpModelName));
                    if (!string.IsNullOrEmpty(hpModel))
                    {
                        r.Model = hpModel;
                        r.ModelSource = "HP-LASERJET-COMMON-MIB model-name";
                    }
                    else
                    {
                        string pname = ValueFormat.AsDisplayString(resp.Find(Oids.PrtGeneralPrinterName));
                        if (!string.IsNullOrEmpty(pname))
                        {
                            r.Model = pname;
                            r.ModelSource = "prtGeneralPrinterName";
                        }
                    }
                }

                string serial = ValueFormat.AsDisplayString(resp.Find(Oids.PrtGeneralSerialNumber));
                if (!string.IsNullOrEmpty(serial))
                {
                    r.Serial = serial;
                    r.SerialSource = "prtGeneralSerialNumber";
                }
                else
                {
                    string hpSerial = ValueFormat.AsDisplayString(resp.Find(Oids.HpSerialNumber));
                    if (!string.IsNullOrEmpty(hpSerial))
                    {
                        r.Serial = hpSerial;
                        r.SerialSource = "HP-LASERJET-COMMON-MIB serial-number";
                    }
                }

                string total = ValueFormat.AsMeterCount(resp.Find(Oids.PrtMarkerLifeCount));
                if (!string.IsNullOrEmpty(total))
                {
                    r.Total = total;
                    r.TotalSource = "prtMarkerLifeCount";
                }

                r.Mono = ValueFormat.AsMeterCount(resp.Find(Oids.HpTotalMonoPageCount));
                r.Color = ValueFormat.AsMeterCount(resp.Find(Oids.HpTotalColorPageCount));

                if (string.IsNullOrEmpty(r.Model))
                {
                    TryFillFromWalk(client, host, Oids.HrDeviceDescrPrefix, r, "model");
                }
                if (string.IsNullOrEmpty(r.Serial))
                {
                    TryFillFromWalk(client, host, Oids.PrtGeneralSerialPrefix, r, "serial");
                }
                if (string.IsNullOrEmpty(r.Total))
                {
                    TryFillFromWalk(client, host, Oids.PrtMarkerLifePrefix, r, "total");
                }

                if (string.IsNullOrEmpty(r.SysDescr) && string.IsNullOrEmpty(r.Model) &&
                    string.IsNullOrEmpty(r.Serial) && string.IsNullOrEmpty(r.Total) &&
                    string.IsNullOrEmpty(r.Mono) && string.IsNullOrEmpty(r.Color))
                {
                    r.Status = "No data";
                    r.ErrorMessage = "Device answered SNMP but returned none of the printer OIDs.";
                }
                else
                {
                    r.Status = "OK";
                }
            }
            catch (TimeoutException ex)
            {
                r.Status = "Timeout";
                r.ErrorMessage = ex.Message;
            }
            catch (Exception ex)
            {
                r.Status = "Error";
                r.ErrorMessage = ex.Message;
            }
            return r;
        }

        private static void TryFillFromWalk(SnmpClient client, string host, string prefix, PrinterReading r, string field)
        {
            try
            {
                List<SnmpValue> walked = client.Walk(host, prefix, 16);
                for (int i = 0; i < walked.Count; i++)
                {
                    if (field == "model")
                    {
                        string s = ValueFormat.AsDisplayString(walked[i]);
                        if (!string.IsNullOrEmpty(s))
                        {
                            r.Model = s;
                            r.ModelSource = "hrDeviceDescr (walk)";
                            return;
                        }
                    }
                    else if (field == "serial")
                    {
                        string s = ValueFormat.AsDisplayString(walked[i]);
                        if (!string.IsNullOrEmpty(s))
                        {
                            r.Serial = s;
                            r.SerialSource = "prtGeneralSerialNumber (walk)";
                            return;
                        }
                    }
                    else if (field == "total")
                    {
                        string s = ValueFormat.AsMeterCount(walked[i]);
                        if (!string.IsNullOrEmpty(s))
                        {
                            r.Total = s;
                            r.TotalSource = "prtMarkerLifeCount (walk)";
                            return;
                        }
                    }
                }
            }
            catch
            {
                // Walks are best-effort fallbacks; leave the field blank.
            }
        }

        private static SnmpResponse GetOneByOne(SnmpClient client, string host, string[] oids)
        {
            SnmpResponse combined = new SnmpResponse();
            for (int i = 0; i < oids.Length; i++)
            {
                try
                {
                    SnmpResponse one = client.Get(host, oids[i]);
                    if (one.Variables.Count > 0) combined.Variables.Add(one.Variables[0]);
                }
                catch (TimeoutException)
                {
                    if (combined.Variables.Count == 0) throw;
                }
                catch
                {
                    // Skip this OID; leave its field blank.
                }
            }
            if (combined.Variables.Count == 0)
                throw new TimeoutException("SNMP timeout contacting " + host);
            return combined;
        }

        public static List<PrinterReading> QueryMany(SnmpClient template, IList<string> hosts, int concurrency, Action<int, int, PrinterReading> progress)
        {
            if (concurrency < 1) concurrency = 1;
            if (concurrency > 64) concurrency = 64;
            PrinterReading[] results = new PrinterReading[hosts.Count];
            int done = 0;
            ThreadPool.SetMinThreads(concurrency, concurrency);
            using (ManualResetEvent finished = new ManualResetEvent(false))
            {
                if (hosts.Count == 0) return new List<PrinterReading>();
                int remaining = hosts.Count;
                Semaphore gate = new Semaphore(concurrency, concurrency);
                for (int i = 0; i < hosts.Count; i++)
                {
                    int idx = i;
                    gate.WaitOne();
                    ThreadPool.QueueUserWorkItem(delegate
                    {
                        try
                        {
                            SnmpClient c = new SnmpClient();
                            c.Community = template.Community;
                            c.Port = template.Port;
                            c.TimeoutMs = template.TimeoutMs;
                            c.Retries = template.Retries;
                            c.Version = template.Version;
                            PrinterReading reading = Query(c, hosts[idx]);
                            results[idx] = reading;
                            int d = Interlocked.Increment(ref done);
                            if (progress != null)
                            {
                                try { progress(d, hosts.Count, reading); }
                                catch { }
                            }
                        }
                        finally
                        {
                            gate.Release();
                            if (Interlocked.Decrement(ref remaining) == 0) finished.Set();
                        }
                    });
                }
                finished.WaitOne();
                gate.Close();
            }
            List<PrinterReading> list = new List<PrinterReading>(results.Length);
            for (int i = 0; i < results.Length; i++) list.Add(results[i]);
            return list;
        }
    }
}
