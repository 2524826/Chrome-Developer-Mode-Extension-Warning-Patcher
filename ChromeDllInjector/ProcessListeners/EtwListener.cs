using Microsoft.Diagnostics.Tracing.Parsers;
using Microsoft.Diagnostics.Tracing.Parsers.Kernel;
using Microsoft.Diagnostics.Tracing.Session;
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Vanara.PInvoke;

namespace ChromeDllInjector.ProcessListeners {
	public class EtwListener : IProcessListener {
		private const int FastFlushMilliseconds = 5;
		private const int IdleFlushMilliseconds = 50;
		private const int RecentInputWindowMilliseconds = 2000;
		private static readonly TimeSpan StartupFastWindow = TimeSpan.FromMinutes(3);
		private Action<int> processCallback;

		[StructLayout(LayoutKind.Sequential)]
		private struct LASTINPUTINFO {
			public uint cbSize;
			public uint dwTime;
		}

		[DllImport("user32.dll")]
		[return: MarshalAs(UnmanagedType.Bool)]
		private static extern bool GetLastInputInfo(ref LASTINPUTINFO inputInfo);

		public void StartListener(Action<int> callback) {
			this.processCallback = callback;

			TraceEventSession kernelSession = new TraceEventSession("ChromePatcherETW");
			kernelSession.EnableKernelProvider(KernelTraceEventParser.Keywords.Process);
			kernelSession.Source.Kernel.ProcessStart += this.Kernel_ProcessStart;

			new Thread(() => { // Required because of blocking Process() below
				Stopwatch uptime = Stopwatch.StartNew();

				AdvApi32.EVENT_TRACE_PROPERTIES properties = new AdvApi32.EVENT_TRACE_PROPERTIES {
					Wnode = new AdvApi32.WNODE_HEADER {
						BufferSize = 1024 // Max buffer size
					}
				};

				AdvApi32.QueryTrace(0 /* NULL Handle */, kernelSession.SessionName, ref properties); // Fill the struct with info
				Console.WriteLine("Flush thread started: " + properties.Wnode.Guid);

				while (true) {
					bool fastFlush = uptime.Elapsed < StartupFastWindow || WasInputReceivedRecently();
					Thread.Sleep(fastFlush ? FastFlushMilliseconds : IdleFlushMilliseconds);
					try {
						AdvApi32.FlushTrace(0 /* NULL Handle */, kernelSession.SessionName, ref properties);
					} catch (Exception) { }
				}
			}).Start();

			Console.WriteLine("Starting to process; ETW flush interval is 5 ms during startup/recent input and 50 ms while idle");
			kernelSession.Source.Process(); // Blocking forever
		}

		private static bool WasInputReceivedRecently() {
			LASTINPUTINFO inputInfo = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>() };
			if (!GetLastInputInfo(ref inputInfo)) {
				return false;
			}
			uint elapsed = unchecked((uint)Environment.TickCount - inputInfo.dwTime);
			return elapsed <= RecentInputWindowMilliseconds;
		}

		private void Kernel_ProcessStart(ProcessTraceData obj) {
			this.processCallback(obj.ProcessID);
		}
	}
}
