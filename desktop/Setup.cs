// Copyright (c) Offline Backup Guard contributors. MIT licensed; see LICENSE.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace BackupDesktop {
    public sealed class Installed { public string Version, PayloadHash, Name, AppId; }
    static class Setup {
        const string RunKey=@"Software\Microsoft\Windows\CurrentVersion\Run";
        static string UninstallKey {get{return @"Software\Microsoft\Windows\CurrentVersion\Uninstall\"+Common.Brand.AppId;}}
        static string DesktopLink {get{return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),Common.Brand.Name+".lnk");}}
        static string MenuRoot {get{return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs),Common.Brand.Name);}}
        static string MenuLink {get{return Path.Combine(MenuRoot,Common.Brand.Name+".lnk");}}
        static string[] Links {get{return new[]{DesktopLink,MenuLink,Path.Combine(MenuRoot,"Uninstall.lnk")};}}
        sealed class Snapshot {
            public Dictionary<string,byte[]> Files=new Dictionary<string,byte[]>();
            public Dictionary<string,object> Values=new Dictionary<string,object>();
            public Dictionary<string,RegistryValueKind> Kinds=new Dictionary<string,RegistryValueKind>();
            public object Startup;public RegistryValueKind StartupKind;public bool HadKey,HadMenu;
            public Snapshot() {
                HadMenu=Directory.Exists(MenuRoot);
                foreach(string path in Links)Files[path]=File.Exists(path)?File.ReadAllBytes(path):null;
                using(var run=Registry.CurrentUser.OpenSubKey(RunKey))if(run!=null){Startup=run.GetValue(Common.Brand.AppId,null,RegistryValueOptions.DoNotExpandEnvironmentNames);if(Startup!=null)StartupKind=run.GetValueKind(Common.Brand.AppId);}
                using(var key=Registry.CurrentUser.OpenSubKey(UninstallKey))if(key!=null){HadKey=true;foreach(string name in key.GetValueNames()){Values[name]=key.GetValue(name,null,RegistryValueOptions.DoNotExpandEnvironmentNames);Kinds[name]=key.GetValueKind(name);}}
            }
            public void Restore() {
                foreach(var file in Files){if(file.Value==null){if(File.Exists(file.Key))File.Delete(file.Key);}else{Directory.CreateDirectory(Path.GetDirectoryName(file.Key));File.WriteAllBytes(file.Key,file.Value);}}
                if(!HadMenu&&Directory.Exists(MenuRoot)&&Directory.GetFileSystemEntries(MenuRoot).Length==0)Directory.Delete(MenuRoot);
                using(var run=Registry.CurrentUser.CreateSubKey(RunKey)){if(Startup==null)run.DeleteValue(Common.Brand.AppId,false);else run.SetValue(Common.Brand.AppId,Startup,StartupKind);}
                Registry.CurrentUser.DeleteSubKeyTree(UninstallKey,false);
                if(HadKey)using(var key=Registry.CurrentUser.CreateSubKey(UninstallKey))foreach(var value in Values)key.SetValue(value.Key,value.Value,Kinds[value.Key]);
            }
        }
        static void CheckOwnership(Installed old) {
            foreach(string path in Links) {
                Common.NoReparse(path);if(Directory.Exists(path))throw new Exception("Shortcut path is occupied by a directory: "+path);if(!File.Exists(path))continue;
                if(old==null)throw new Exception("Unowned shortcut collision: "+path);
                dynamic shell=Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
                try {dynamic link=shell.CreateShortcut(path);try {
                    bool uninstall=path==Path.Combine(MenuRoot,"Uninstall.lnk");
                    string expected=Common.Child(Common.InstallRoot,"versions\\"+old.Version+(uninstall?"\\Setup.exe":"\\Desktop.exe"));
                    if(!String.Equals((string)link.TargetPath,expected,StringComparison.OrdinalIgnoreCase)||(string)link.Arguments!=(uninstall?"--uninstall":""))throw new Exception("Shortcut was changed; refusing to replace or remove: "+path);
                }finally{System.Runtime.InteropServices.Marshal.FinalReleaseComObject(link);}}finally{System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell);}
            }
            using(var run=Registry.CurrentUser.OpenSubKey(RunKey)) {
                object value=run==null?null:run.GetValue(Common.Brand.AppId,null,RegistryValueOptions.DoNotExpandEnvironmentNames);
                if(value!=null&&(old==null||(string)value!=Common.Quote(Common.Child(Common.InstallRoot,"versions\\"+old.Version+"\\Desktop.exe"))+" --tray"))throw new Exception("Login startup value is not owned by this installation.");
            }
            using(var key=Registry.CurrentUser.OpenSubKey(UninstallKey))if(key!=null) {
                if(old==null||(string)key.GetValue("InstallLocation")!=Common.InstallRoot||(string)key.GetValue("UninstallString")!=Common.Quote(Common.Child(Common.InstallRoot,"versions\\"+old.Version+"\\Setup.exe"))+" --uninstall")throw new Exception("Uninstall registration is not owned by this installation.");
            }
        }
        static void Shortcut(string path,string target,string arguments) {
            Common.NoReparse(path);Directory.CreateDirectory(Path.GetDirectoryName(path));
            Type type=Type.GetTypeFromProgID("WScript.Shell");dynamic shell=Activator.CreateInstance(type);
            try {dynamic link=shell.CreateShortcut(path);try {link.TargetPath=target;link.Arguments=arguments;link.WorkingDirectory=Path.GetDirectoryName(target);link.IconLocation=target+",0";link.Description=Common.Brand.Name;link.Save();}finally{System.Runtime.InteropServices.Marshal.FinalReleaseComObject(link);}}
            finally{System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell);}
        }
        static Installed ReadInstalled() {
            string path=Common.Child(Common.InstallRoot,"current.json");
            if(!File.Exists(path)) return null;
            var result=Common.Json.Deserialize<Installed>(File.ReadAllText(path));
            if(result.AppId!=Common.Brand.AppId||result.Name!=Common.Brand.Name) throw new Exception("Installed application identity differs. Refusing replacement.");
            new Version(result.Version);return result;
        }
        static void Integrate(string version,bool startup) {
            string target=Common.Child(Common.InstallRoot,"versions\\"+version+"\\Desktop.exe");
            string setup=Common.Child(Common.InstallRoot,"versions\\"+version+"\\Setup.exe");
            Shortcut(DesktopLink,target,"");Shortcut(MenuLink,target,"");
            Shortcut(Path.Combine(MenuRoot,"Uninstall.lnk"),setup,"--uninstall");
            using(var run=Registry.CurrentUser.CreateSubKey(RunKey)) {if(startup)run.SetValue(Common.Brand.AppId,Common.Quote(target)+" --tray");else run.DeleteValue(Common.Brand.AppId,false);}
            using(var key=Registry.CurrentUser.CreateSubKey(UninstallKey)) {
                key.SetValue("DisplayName",Common.Brand.Name);key.SetValue("DisplayVersion",version);key.SetValue("Publisher","Offline Backup Guard contributors");
                key.SetValue("InstallLocation",Common.InstallRoot);key.SetValue("DisplayIcon",target+",0");
                key.SetValue("UninstallString",Common.Quote(setup)+" --uninstall");key.SetValue("NoModify",1);key.SetValue("NoRepair",1);
            }
        }
        static void Install(bool startup) {
            Common.NoReparse(Common.InstallRoot);Directory.CreateDirectory(Common.InstallRoot);
            var old=ReadInstalled();
            CheckOwnership(old);
            if(old!=null && new Version(Common.Brand.Version)<new Version(old.Version)) throw new Exception("Downgrade refused. Installed version: "+old.Version);
            string stage=Common.Child(Common.InstallRoot,"stage-"+Guid.NewGuid().ToString("N"));
            string versionDir=Common.Child(Common.InstallRoot,"versions\\"+Common.Brand.Version);
            Directory.CreateDirectory(stage);
            try {
                using(var resource=Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
                using(var zip=new ZipArchive(resource,ZipArchiveMode.Read)) {
                    foreach(var entry in zip.Entries) {
                        if(String.IsNullOrEmpty(entry.Name))continue;
                        string path=Common.Child(stage,entry.FullName);Directory.CreateDirectory(Path.GetDirectoryName(path));
                        using(var input=entry.Open())using(var output=new FileStream(path,FileMode.CreateNew)) input.CopyTo(output);
                    }
                }
                Common.Verify(stage);
                string payloadHash=Common.Hash(Common.Child(stage,"Desktop.exe"));
                string setupHash=Common.Hash(Assembly.GetExecutingAssembly().Location);
                if(old!=null && old.Version==Common.Brand.Version && old.PayloadHash!=payloadHash) throw new Exception("Immutable version conflict. Build changed content with a new version.");
                string marker=Path.Combine(versionDir,"installing.txt");
                Common.NoReparse(marker);Common.NoReparse(Path.Combine(versionDir,"Setup.exe"));Common.NoReparse(Path.Combine(versionDir,"complete.txt"));
                bool partial=File.Exists(marker);
                if(partial && File.ReadAllText(marker)!=payloadHash)throw new Exception("Incomplete version belongs to a different package. Preserve it for inspection and use a new version.");
                bool emptyVersion=!Directory.Exists(versionDir)||Directory.GetFileSystemEntries(versionDir).Length==0;
                if(!emptyVersion&&!partial) {
                    Common.Verify(versionDir);
                    if(Common.Hash(Path.Combine(versionDir,"Desktop.exe"))!=payloadHash)throw new Exception("Existing version differs; refusing overwrite.");
                    if(!File.Exists(Path.Combine(versionDir,"complete.txt"))||File.ReadAllText(Path.Combine(versionDir,"complete.txt"))!=setupHash||Common.Hash(Path.Combine(versionDir,"Setup.exe"))!=setupHash)throw new Exception("Installed setup is missing or differs. Refusing activation.");
                } else {
                    Directory.CreateDirectory(versionDir);
                    if(!partial) {
                        // A crash before publication leaves an empty, retryable version directory.
                        string pendingMarker=Common.Child(stage,"installing-"+Guid.NewGuid().ToString("N")+".tmp");
                        using(var stream=new FileStream(pendingMarker,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
                            byte[] bytes=System.Text.Encoding.UTF8.GetBytes(payloadHash);
                            stream.Write(bytes,0,bytes.Length);stream.Flush(true);
                        }
                        File.Move(pendingMarker,marker);
                    }
                    foreach(string file in Directory.GetFiles(stage,"*",SearchOption.AllDirectories)) {
                        string relative=file.Substring(stage.Length+1);string target=Common.Child(versionDir,relative);
                        Directory.CreateDirectory(Path.GetDirectoryName(target));File.Copy(file,target,partial);
                    }
                    File.Copy(Assembly.GetExecutingAssembly().Location,Path.Combine(versionDir,"Setup.exe"),partial);
                    Common.Verify(versionDir);
                    if(Common.Hash(Path.Combine(versionDir,"Setup.exe"))!=setupHash)throw new Exception("Installed setup verification failed.");
                    File.WriteAllText(Path.Combine(versionDir,"complete.txt"),setupHash);File.Delete(marker);
                }
                string current=Common.Child(Common.InstallRoot,"current.json");
                string pending=Common.Child(Common.InstallRoot,"current-"+Guid.NewGuid().ToString("N")+".json");
                var snapshot=new Snapshot();
                try {
                    Integrate(Common.Brand.Version,startup);
                    File.WriteAllText(pending,Common.Json.Serialize(new Installed{Version=Common.Brand.Version,PayloadHash=payloadHash,Name=Common.Brand.Name,AppId=Common.Brand.AppId}));
                    if(File.Exists(current))File.Replace(pending,current,null);else File.Move(pending,current);
                }catch {
                    snapshot.Restore();
                    throw;
                }finally{if(File.Exists(pending))File.Delete(pending);}
                Common.TryLog("Installed "+Common.Brand.Version+"; login startup="+startup+". Backup configuration/tasks unchanged.");
            } finally {if(Directory.Exists(stage))Directory.Delete(stage,true);}
        }
        static void RemoveIntegration() {
            foreach(string link in Links) {Common.NoReparse(link);if(File.Exists(link))File.Delete(link);}
            if(Directory.Exists(MenuRoot)&&Directory.GetFileSystemEntries(MenuRoot).Length==0)Directory.Delete(MenuRoot);
            using(var run=Registry.CurrentUser.OpenSubKey(RunKey,true))if(run!=null)run.DeleteValue(Common.Brand.AppId,false);
            Registry.CurrentUser.DeleteSubKeyTree(UninstallKey,false);
        }
        static void Execute(bool uninstall,bool startup) {
            using(var gate=new Mutex(false,Common.InstanceName)) {
                if(!Common.Acquire(gate))throw new Exception("Exit the application from its tray menu before changing its installation. No process will be stopped.");
                try {
                    if(uninstall){var old=ReadInstalled();CheckOwnership(old);if(old!=null){var snapshot=new Snapshot();try{RemoveIntegration();}catch{snapshot.Restore();throw;}}Common.TryLog("Desktop integration removed. Versioned runners, configuration, tasks and backup data retained.");}
                    else Install(startup);
                }finally{gate.ReleaseMutex();}
            }
        }
        [STAThread] static int Main(string[] args) {
            bool quiet=Array.IndexOf(args,"--quiet")>=0||Array.IndexOf(args,"--install")>=0;
            try {
                Common.Validate(true);
                foreach(string a in args)if(a!="--install"&&a!="--uninstall"&&a!="--startup"&&a!="--no-startup"&&a!="--quiet")throw new Exception("Unknown setup argument: "+a);
                bool uninstall=Array.IndexOf(args,"--uninstall")>=0;
                if(uninstall&&Array.IndexOf(args,"--install")>=0)throw new Exception("Choose install or uninstall.");
                if(uninstall) {
                    if(!quiet&&MessageBox.Show("Remove desktop shortcuts and login startup?\n\nVersioned runners, scheduled backup tasks, settings and backup data will be kept.",Common.Brand.Name,MessageBoxButtons.YesNo,MessageBoxIcon.Question)!=DialogResult.Yes)return 0;
                    Execute(true,false);return 0;
                }
                if(args.Length>0) {
                    bool on=Array.IndexOf(args,"--startup")>=0,off=Array.IndexOf(args,"--no-startup")>=0;
                    if(Array.IndexOf(args,"--install")<0||on==off)throw new Exception("Use --install with exactly one of --startup or --no-startup.");
                    Execute(false,on);return 0;
                }
                Application.EnableVisualStyles();
                int outcome=0;
                using(var form=new Form())using(var icon=Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location)) {
                    form.Text=Common.Brand.Name+" Setup";form.Icon=icon;form.ClientSize=new Size(520,240);form.FormBorderStyle=FormBorderStyle.FixedDialog;form.MaximizeBox=false;form.StartPosition=FormStartPosition.CenterScreen;form.Font=new Font("Segoe UI",10);
                    var label=new Label{Left=20,Top=20,Width=480,Height=100,Text="Install "+Common.Brand.Name+" "+Common.Brand.Version+" for the current Windows user.\n\nCreates desktop and Start menu shortcuts. Existing backup settings and scheduled tasks are not changed."};
                    var startup=new CheckBox{Left=20,Top=128,Width=470,Height=30,Text="Start the tray app when I sign in",Checked=true};
                    var existing=ReadInstalled();CheckOwnership(existing);
                    if(existing!=null)using(var run=Registry.CurrentUser.OpenSubKey(RunKey))startup.Checked=run!=null&&run.GetValue(Common.Brand.AppId)!=null;
                    var install=new Button{Left=310,Top=188,Width=90,Text="Install"};var cancel=new Button{Left=410,Top=188,Width=90,Text="Cancel",DialogResult=DialogResult.Cancel};
                    install.Click+=(s,e)=>{try {Execute(false,startup.Checked);outcome=0;MessageBox.Show("Installation complete. Open the desktop shortcut to start the app.",Common.Brand.Name);form.Close();}catch(Exception ex){outcome=1;Common.Error(ex,false);}};
                    form.Controls.AddRange(new Control[]{label,startup,install,cancel});form.CancelButton=cancel;Application.Run(form);
                }
                return outcome;
            }catch(Exception e){Common.Error(e,quiet);return 1;}
        }
    }
}
