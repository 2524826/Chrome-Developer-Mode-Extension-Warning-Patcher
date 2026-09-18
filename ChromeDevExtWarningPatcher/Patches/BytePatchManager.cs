using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Windows;
using System.Xml.Linq;
using ChromeDevExtWarningPatcher.ComponentModels;

namespace ChromeDevExtWarningPatcher.Patches {
	public class BytePatchManager {
		public List<BytePatch> BytePatches = new List<BytePatch>();
		public delegate MessageBoxResult WriteLineOrMessageBox(string str, string title);
		private readonly Dictionary<string, BytePatchPattern> bytePatterns = new Dictionary<string, BytePatchPattern>();


		public BytePatchManager(WriteLineOrMessageBox log, SelectionListModel? selectionList = null) {
			this.BytePatches.Clear();
			this.bytePatterns.Clear();

			using Stream rulesStream = Assembly.GetExecutingAssembly().GetManifestResourceStream(
				"ChromeDevExtWarningPatcher.patterns.xml") ??
				throw new InvalidDataException("Embedded patterns.xml is missing.");
			XDocument xmlDoc = XDocument.Load(rulesStream, LoadOptions.SetLineInfo);

#nullable disable // Many things could be null here, but a crash would be wanted

			Thread.CurrentThread.CurrentCulture = CultureInfo.InvariantCulture;

			float newVersion = float.Parse(xmlDoc.Root.Attribute("version").Value);
			Version myVersion = Assembly.GetCallingAssembly().GetName().Version;

			if (newVersion > float.Parse(myVersion.Major + "." + myVersion.Minor)) {
				log("A new version of this patcher has been found.\nDownload it at:\nhttps://github.com/Ceiridge/Chrome-Developer-Mode-Extension-Warning-Patcher/releases", "New update available");
			}

			foreach (XElement pattern in xmlDoc.Root.Element("Patterns").Elements("Pattern")) {
				BytePatchPattern patternClass = new BytePatchPattern(pattern.Attribute("name").Value);

				foreach (XElement bytePattern in pattern.Elements("BytePattern")) {
					string[] unparsedBytes = bytePattern.Value.Split(' ');
					byte[] patternBytesArr = new byte[unparsedBytes.Length];

					for (int i = 0; i < unparsedBytes.Length; i++) {
						string unparsedByte = unparsedBytes[i].Equals("?") ? "FF" : unparsedBytes[i];
						patternBytesArr[i] = Convert.ToByte(unparsedByte, 16);
					}
					patternClass.AlternativePatternsX64.Add(patternBytesArr);
				}

				this.bytePatterns.Add(patternClass.Name, patternClass);
			}

			foreach (XElement patch in xmlDoc.Root.Element("Patches").Elements("Patch")) {
				BytePatchPattern pattern = this.bytePatterns[patch.Attribute("pattern").Value];
				int group = int.Parse(patch.Attribute("group").Value);

				byte origX64 = 0, patchX64 = 0;
				List<int> offsetsX64 = new List<int>();
				byte[] newBytes = null;
				int sigOffset = 0;
				bool sig = false;

				foreach (XElement patchData in patch.Elements("PatchData")) {
					foreach (XElement offsetElement in patchData.Elements("Offset")) {
						offsetsX64.Add(Convert.ToInt32(offsetElement.Value.Replace("0x", ""), 16));
					}

					if (patchData.Element("NewBytes") != null) {
						newBytes = Convert.FromHexString(patchData.Element("NewBytes").Value);
					}

					origX64 = Convert.ToByte(patchData.Attribute("orig").Value.Replace("0x", ""), 16);
					patchX64 = Convert.ToByte(patchData.Attribute("patch").Value.Replace("0x", ""), 16);
					sig = Convert.ToBoolean(patchData.Attribute("sig").Value);
					if (patchData.Attributes("sigOffset").Any()) {
						sigOffset = Convert.ToInt32(patchData.Attribute("sigOffset").Value.Replace("0x", ""), 16);
					}
					break;
				}

				this.BytePatches.Add(new BytePatch(pattern, origX64, patchX64, offsetsX64, @group, newBytes, sig, sigOffset));
			}

			if (selectionList != null) {
				foreach (XElement patchGroup in xmlDoc.Root.Element("GroupedPatches").Elements("GroupedPatch")) {
					selectionList.ElementList.Add(new PatchGroupElement(patchGroup.Element("Name").Value, int.Parse(patchGroup.Attribute("group").Value)) {
						IsSelected = bool.Parse(patchGroup.Attribute("default").Value),
						Description = patchGroup.Element("Tooltip").Value
					});
				}
			}

#nullable restore

		}
	}
}
