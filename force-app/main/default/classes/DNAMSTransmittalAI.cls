/**
 * @description     Generates one transmittal summary (Ownership or Executive) from its prompt template. Implemented by
 *                  DNAMSEinsteinTransmittalAI; tests inject a stub into DNAMSTransmittalSummaryService.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-05
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-05   Abhishek Dutta  Initial version
 **/
public interface DNAMSTransmittalAI {
    /**
     * @description Sends the context to the prompt template and returns the raw model answer.
     * @param promptTemplate Prompt template API name
     * @param contextJson    Summary context JSON (the template's 'context' input)
     * @return               Raw text: JSON {"lines": ["..."]}
     **/
    String generate(String promptTemplate, String contextJson);
}
