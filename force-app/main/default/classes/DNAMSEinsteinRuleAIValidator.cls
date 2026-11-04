/**
 * @description     Calls the rule validation prompt template (DNAMS_RuleValidation_Prompt) through the Einstein
 *                  Models API with the comparisons JSON as its single text input.
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-04
 * @last modified by Sachin Mondal
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-04   Sachin Mondal   Initial version
 **/
public with sharing class DNAMSEinsteinRuleAIValidator implements DNAMSRuleAIValidator {
    /**
     * @description See DNAMSRuleAIValidator.validate.
     * @param promptTemplate  Prompt template API name
     * @param comparisonsJson JSON array of comparisons
     * @return                The model's text
     * @throws DNAMSPipelineException when the model returns nothing
     **/
    public String validate(String promptTemplate, String comparisonsJson) {
        ConnectApi.WrappedValue comparisons = new ConnectApi.WrappedValue();
        comparisons.value = comparisonsJson;
        ConnectApi.EinsteinPromptTemplateGenerationsInput request = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        request.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:comparisons' => comparisons };
        request.isPreview = false;
        request.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        request.additionalConfig.applicationName = 'PromptBuilderPreview';

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
            promptTemplate,
            request
        );
        if (response.generations == null || response.generations.isEmpty() || String.isBlank(response.generations[0].text)) {
            throw new DNAMSPipelineException('The model returned no rule verdicts.');
        }
        return response.generations[0].text;
    }
}
