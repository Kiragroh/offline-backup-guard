using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using BackupDesktop;

static class DesktopCommonTests {
    static int Main(string[] args) {
        Console.OutputEncoding=new System.Text.UTF8Encoding(false);
        if(args.Length>0&&args[0]=="--echo") {Console.Write(Common.Json.Serialize(args.Skip(1).ToArray()));return 0;}
        try {
            string[] expected={"","normal","space path"," leading ","trailing ","tab\tvalue",@"C:\space path\", "embedded\"quote", "slash\\\"quote", "apostrophe's", "two\\\\", "\u00FCnicode"};
            var info=new ProcessStartInfo(System.Reflection.Assembly.GetExecutingAssembly().Location);
            info.UseShellExecute=false;info.CreateNoWindow=true;info.RedirectStandardOutput=true;
            info.StandardOutputEncoding=System.Text.Encoding.UTF8;
            info.Arguments="--echo "+String.Join(" ",expected.Select(Common.Quote));
            using(var p=Process.Start(info)) {
                string[] actual=Common.Json.Deserialize<string[]>(p.StandardOutput.ReadToEnd());p.WaitForExit();
                if(p.ExitCode!=0||!expected.SequenceEqual(actual))throw new Exception("Windows command-line quoting changed literal arguments.");
            }
            Console.WriteLine("PASS native Windows argument round trip: empty, Unicode, apostrophe, whitespace, quotes and trailing backslashes");
            foreach(string bad in new[]{@"..\outside",@"C:\outside","name:stream"}) {
                bool rejected=false;try{Common.Child(Path.GetTempPath(),bad);}catch(IOException){rejected=true;}
                if(!rejected)throw new Exception("Unsafe child path accepted: "+bad);
            }
            Console.WriteLine("PASS native package traversal, absolute path and alternate stream rejection");
            return 0;
        }catch(Exception e){Console.Error.WriteLine(e);return 1;}
    }
}
