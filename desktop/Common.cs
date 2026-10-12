// Copyright (c) Offline Backup Guard contributors. MIT licensed; see LICENSE.
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace BackupDesktop {
    public sealed class Profile {
        public string Name, AppId, EntryScript, Version;
        public bool AllowAdministrativeLaunch;
        public Dictionary<string,string> Files;
    }
    public static class Common {
        public static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        public static readonly Profile Brand = Json.Deserialize<Profile>(ResourceText("brand.json"));
        public static string ResourceText(string name) {
            using(var s=Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            using(var r=new StreamReader(s)) return r.ReadToEnd();
        }
        public static string Sid { get { return WindowsIdentity.GetCurrent().User.Value; } }
        public static string InstanceName { get { return "Local\\"+Brand.AppId+"."+Sid+".Instance"; } }
        public static string FocusName { get { return "Local\\"+Brand.AppId+"."+Sid+".Focus"; } }
        public static string InstallRoot { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Programs",Brand.AppId); } }
        public static string DataRoot { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),Brand.AppId); } }
        public static bool IsElevated {get{return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);}}
        public static void Validate(bool setup) {
            if(!Regex.IsMatch(Brand.AppId,@"^[A-Za-z][A-Za-z0-9.-]{2,79}$") ||
                Brand.Name.IndexOfAny(Path.GetInvalidFileNameChars())>=0 || String.IsNullOrWhiteSpace(Brand.Name)) throw new Exception("Invalid application identity.");
            new Version(Brand.Version);
#if DESKTOP_TESTS
            // Compile-time CI exception; never available to production binaries.
            if(!Regex.IsMatch(Brand.AppId,@"\ABackupGuardTest\.[a-f0-9]{32}\z") ||
                !Regex.IsMatch(Brand.Name,@"\ABackup Guard Test [a-f0-9]{32}\z") ||
                Brand.EntryScript!=@"tests\fixtures\DesktopProbe.ps1")
                throw new Exception("TestBuild requires the isolated test identity, name and desktop probe.");
#else
            if(IsElevated && (setup || !Brand.AllowAdministrativeLaunch))
                throw new Exception("Start this per-user application without administrator elevation. Backup elevation is a separate explicit editor action.");
#endif
        }
        public static void NoReparse(string path) {
            for(string p=Path.GetFullPath(path);!String.IsNullOrEmpty(p);p=Path.GetDirectoryName(p))
                if((File.Exists(p)||Directory.Exists(p)) && (File.GetAttributes(p)&FileAttributes.ReparsePoint)!=0)
                    throw new IOException("Reparse points are not allowed in application paths: "+p);
        }
        public static string Child(string root,string relative) {
            if(Path.IsPathRooted(relative)||relative.Contains(":")) throw new IOException("Unsafe package path.");
            string prefix=Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar;
            string full=Path.GetFullPath(Path.Combine(prefix,relative));
            if(Path.IsPathRooted(relative)||!full.StartsWith(prefix,StringComparison.OrdinalIgnoreCase)||relative.Contains(":")) throw new IOException("Unsafe package path.");
            NoReparse(full); return full;
        }
        public static string Hash(string path) { using(var h=SHA256.Create()) using(var s=File.OpenRead(path)) return BitConverter.ToString(h.ComputeHash(s)).Replace("-",""); }
        public static void Verify(string root) {
            foreach(var pair in Brand.Files) if(!String.Equals(Hash(Child(root,pair.Key)),pair.Value,StringComparison.OrdinalIgnoreCase))
                throw new IOException("Application integrity check failed: "+pair.Key+". Reinstall a trusted package.");
        }
        // CommandLineToArgvW-compatible quoting, including a trailing backslash.
        public static string Quote(string value) {
            var b=new StringBuilder("\"");int slashes=0;
            foreach(char c in value) {
                if(c=='\\') {slashes++;continue;}
                b.Append('\\',c=='"'?slashes*2+1:slashes);b.Append(c);slashes=0;
            }
            b.Append('\\',slashes*2);b.Append('"');return b.ToString();
        }
        public static bool Acquire(System.Threading.Mutex mutex) {
            try{return mutex.WaitOne(0);}catch(System.Threading.AbandonedMutexException){return true;}
        }
        public static void Log(string text) {
            string dir=Path.Combine(DataRoot,"desktop-logs"); NoReparse(dir);Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir,DateTime.UtcNow.ToString("yyyy-MM-dd")+".log"),DateTime.UtcNow.ToString("o")+" "+text+Environment.NewLine,Encoding.UTF8);
        }
        public static void TryLog(string text) {try{Log(text);}catch(Exception e){System.Diagnostics.Debug.WriteLine(e);}}
        public static void Error(Exception error,bool quiet) {
            string message=error.Message;
            try {Log(error.ToString());message+="\n\nDetails: "+Path.Combine(DataRoot,"desktop-logs");} catch(Exception logError) {message+="\nLog could not be written: "+logError.Message;}
            if(!quiet) MessageBox.Show(message,Brand.Name,MessageBoxButtons.OK,MessageBoxIcon.Error);
        }
    }
}
