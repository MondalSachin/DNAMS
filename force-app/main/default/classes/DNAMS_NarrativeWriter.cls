/**
 * Step 18: writes the package AI narrative for a completed run from its Issue Summary.
 * The Einstein implementation is used at runtime; tests inject a stub.
 */
public interface DNAMS_NarrativeWriter {
    String write(String promptTemplate, Id runId);
}