// Copyright (c) Offline Backup Guard contributors. MIT licensed; see LICENSE.
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace BackupDesktop {
    static class Launcher {
        [STAThread] static int Main(string[] args) {
            try {
                Common.Validate(false); bool tray=false;
                foreach(string arg in args) { if(arg=="--tray") tray=true;else throw new ArgumentException("Supported argument: --tray"); }
                using(var focus=new EventWaitHandle(false,EventResetMode.AutoReset,Common.FocusName))
                using(var instance=new Mutex(false,Common.InstanceName)) {
                    if(!Common.Acquire(instance)) {
                        string owner=Path.Combine(Common.DataRoot,"desktop-instance.txt");
                        if(File.Exists(owner)&&File.ReadAllText(owner)!=(Common.IsElevated?"elevated":"standard"))throw new Exception("The app is already open at a different privilege level. Exit that instance explicitly before changing privilege level.");
                        focus.Set();
                        return 0;
                    }
                    try {
                        {
                            string root=AppDomain.CurrentDomain.BaseDirectory;
                            Common.Verify(root);
                            Common.NoReparse(Common.DataRoot);Directory.CreateDirectory(Common.DataRoot);
                            File.WriteAllText(Path.Combine(Common.DataRoot,"desktop-instance.txt"),Common.IsElevated?"elevated":"standard");
                            var info=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),@"System32\WindowsPowerShell\v1.0\powershell.exe"));
                            info.UseShellExecute=false;info.CreateNoWindow=true;info.WorkingDirectory=root;
                            info.RedirectStandardOutput=true;info.RedirectStandardError=true;
                            info.Arguments="-NoProfile -STA -File "+Common.Quote(Common.Child(root,Common.Brand.EntryScript))+" -DesktopEventName "+Common.Quote(Common.FocusName)+(tray?" -Tray":"");
                            using(var child=Process.Start(info)) {
                                var output=child.StandardOutput.ReadToEndAsync();var error=child.StandardError.ReadToEndAsync();
                                Common.TryLog("Editor started; process "+child.Id+"; version "+Common.Brand.Version);
                                child.WaitForExit();
                                string details=output.Result+error.Result;
                                if(!String.IsNullOrWhiteSpace(details)) Common.TryLog(details);
                                if(child.ExitCode!=0) throw new Exception("Editor failed (exit "+child.ExitCode+"). Check Windows PowerShell execution policy, package trust and desktop logs. No policy bypass was attempted.\n"+details);
                                return 0;
                            }
                        }
                    } finally {instance.ReleaseMutex();}
                }
            } catch(Exception e) {Common.Error(e,false);return 1;}
        }
    }
}
