/**
 * @description     Judges a batch of AIMatch rule comparisons (rule validation step 15). Implemented by
 *                  DNAMSEinsteinRuleAIValidator; tests inject a stub.
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-04
 * @last modified by Sachin Mondal
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-04   Sachin Mondal   Initial version
 **/
public interface DNAMSRuleAIValidator {
    /**
     * @description Sends the comparisons to the prompt template and returns the raw model answer.
     * @param promptTemplate   Prompt template API name
     * @param comparisonsJson  JSON array of comparisons
     * @return                 Raw text: a JSON array of {rule_id, verdict, reasoning}
     **/
    String validate(String promptTemplate, String comparisonsJson);
}
