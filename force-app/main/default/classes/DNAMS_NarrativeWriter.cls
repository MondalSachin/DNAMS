/**
 * Writes the package summary from the run's facts (JSON). Implemented by DNAMS_EinsteinNarrativeWriter; tests inject
 * a stub. Returns the raw model text, expected to be the summary JSON object.
 */
public interface DNAMS_NarrativeWriter {
    String write(String promptTemplate, String factsJson);
}
