/**
 * Step 13: classifies one document against the type expected for its element and returns the model's raw
 * JSON text. The Einstein implementation is used at runtime; tests inject a stub.
 */
public interface DNAMS_DocumentClassifier {
    String classify(String promptTemplate, Id contentDocumentId, Id elementId);
}