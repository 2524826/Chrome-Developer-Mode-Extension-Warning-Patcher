using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using ChromeDllInjector.ProcessListeners;
using Vanara.PInvoke;

namespace ChromeDllInjector {
	class Program {
		private const int ErrorPartialCopy = 299;
		private static readonly HashSet<string> ChromeExeFilePaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
		private static readonly HashSet<string> ChromeProcessNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
		private static readonly int[] PathRetryDelaysMilliseconds = { 25, 50, 100 };
		private static Injector Injector;
		private static IProcessListener Listener;

		static void Main(string[] _) {
			try {
#if !DEBUG
				RedirectOutput();
#else
				AttachConsole();
#endif
				CreateInjector();
				LoadChromeExePaths();
			} catch (Exception e) {
				Console.WriteLine("Couldn't initialize: " + e.Message);
				Environment.Exit(1);
			}

			HINSTANCE ntDllInstance = Kernel32.GetModuleHandle("ntdll.dll");
			if (ntDllInstance.IsNull) {
				Console.WriteLine("Ntdll.dll not found!");
				Environment.Exit(1);
			}

			if (Kernel32.GetProcAddress(ntDllInstance, "RtlGetDeviceFamilyInfoEnum") == IntPtr.Zero) {
				Console.WriteLine("ETWs not supported. Having to use compatibility mode!");
				Listener = new CompatibleListener();
			} else {
				Console.WriteLine("ETWs are supported.");
				Listener = new EtwListener();
			}

			Listener.StartListener(OnProcessStart);
		}

		private static void OnProcessStart(int processId) {
			try {
				using Process proc = Process.GetProcessById(processId);
				if (!ChromeProcessNames.Contains(proc.ProcessName)) {
					return;
				}

				long creationTicks;
				try {
					creationTicks = proc.StartTime.ToUniversalTime().Ticks;
				} catch {
					return;
				}

				string? executablePath;
				try {
					executablePath = proc.MainModule?.FileName;
				} catch (Win32Exception e) when (IsRetryableModulePathException(e)) {
					QueuePathRetry(processId, creationTicks);
					return;
				}
				if (string.IsNullOrEmpty(executablePath)) {
					QueuePathRetry(processId, creationTicks);
					return;
				}
				if (!ChromeExeFilePaths.Contains(executablePath)) {
					return;
				}

				Injector.Inject(proc);
			} catch (ArgumentException) {
				// The process exited before its metadata could be read.
			} catch (InvalidOperationException) {
				// The process exited or its Process object became unavailable.
			} catch (Exception e) {
				Console.WriteLine($"Process callback failed pid={processId}: {e.Message}");
			}
		}

		private static bool IsRetryableModulePathException(Win32Exception exception) {
			return exception.NativeErrorCode == ErrorPartialCopy;
		}

		private static void QueuePathRetry(int pid, long creationTicks) {
			Console.WriteLine($"Path retry queued pid={pid}");
			ThreadPool.QueueUserWorkItem(_ => RunPathRetrySafely(pid, creationTicks));
		}

		private static void RunPathRetrySafely(int pid, long creationTicks) {
			try {
				RetryUnavailablePath(pid, creationTicks);
			} catch (Exception e) {
				Console.WriteLine($"Path retry callback failed pid={pid}: {e.Message}");
			}
		}

		private static void RetryUnavailablePath(int pid, long creationTicks) {
			for (int attempt = 0; attempt < PathRetryDelaysMilliseconds.Length; attempt++) {
				int delayMilliseconds = PathRetryDelaysMilliseconds[attempt];
				Thread.Sleep(delayMilliseconds);
				try {
					using Process proc = Process.GetProcessById(pid);
					if (proc.StartTime.ToUniversalTime().Ticks != creationTicks || !ChromeProcessNames.Contains(proc.ProcessName)) {
						return;
					}

					string? executablePath;
					try {
						executablePath = proc.MainModule?.FileName;
					} catch (Win32Exception e) when (IsRetryableModulePathException(e)) {
						continue;
					}
					if (string.IsNullOrEmpty(executablePath)) {
						continue;
					}
					if (!ChromeExeFilePaths.Contains(executablePath)) {
						return;
					}

					Console.WriteLine($"Path retry matched pid={pid} attempt={attempt + 1}");
					Injector.Inject(proc);
					return;
				} catch {
					return;
				}
			}
			Console.WriteLine($"Path retry exhausted pid={pid}");
		}

		private static void AttachConsole() {
			if (!Kernel32.AttachConsole(Kernel32.ATTACH_PARENT_PROCESS)) {
				Kernel32.AllocConsole();
			}
		}

		private static void RedirectOutput() {
			StreamWriter writer;
			Console.SetOut(writer = new StreamWriter(new FileStream(Environment.GetFolderPath(Environment.SpecialFolder.Windows) + @"\Temp\ChromePatcherInjector.log", FileMode.Append, FileAccess.Write, FileShare.Read)));
			writer.AutoFlush = true;
			Console.WriteLine(DateTime.UtcNow.Subtract(new DateTime(1970, 1, 1)).TotalSeconds);
		}

		private static void CreateInjector() {
			DirectoryInfo curDir = new DirectoryInfo(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location));
			FileInfo dll = curDir.EnumerateFiles().Where(file => file.Name.EndsWith(".dll") && file.Name.StartsWith("ChromePatcherDll_")).OrderByDescending(file => file.LastWriteTimeUtc).First();
			Console.WriteLine("Using injector with " + dll.FullName);
			Injector = new Injector(dll.FullName);
		}

		private static void LoadChromeExePaths() {
			using RegistryKey exeKey = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Ceiridge\ChromePatcher\ChromeExes");
			foreach (string name in exeKey.GetValueNames()) {
				if (name.Length < 1) {
					continue;
				}
				string value = exeKey.GetValue(name, "").ToString();
				if (value.Length > 5) {
					ChromeExeFilePaths.Add(value);
					ChromeProcessNames.Add(Path.GetFileNameWithoutExtension(value));
				}
			}
		}
	}
}
