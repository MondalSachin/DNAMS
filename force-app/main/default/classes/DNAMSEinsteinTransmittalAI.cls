/**
 * @description     Calls a transmittal summary prompt template (DNAMS_OwnershipSummary_Prompt or
 *                  DNAMS_ExecutiveSummary_Prompt) through the Einstein Models API with the context JSON as its single
 *                  text input.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-05
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-05   Abhishek Dutta  Initial version
 **/
@SuppressWarnings('PMD.ClassNamingConventions') // name fixed by the transmittal build contract
public with sharing class DNAMSEinsteinTransmittalAI implements DNAMSTransmittalAI {
    /**
     * @description See DNAMSTransmittalAI.generate.
     * @param promptTemplate Prompt template API name
     * @param contextJson    Summary context JSON
     * @return               The model's text
     * @throws DNAMSPipelineException when the model returns nothing
     **/
    public String generate(String promptTemplate, String contextJson) {
        ConnectApi.WrappedValue context = new ConnectApi.WrappedValue();
        context.value = contextJson;
        ConnectApi.EinsteinPromptTemplateGenerationsInput request = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        request.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:context' => context };
        request.isPreview = false;
        request.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        request.additionalConfig.applicationName = 'PromptBuilderPreview';

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
            promptTemplate,
            request
        );
        if (response.generations == null || response.generations.isEmpty() || String.isBlank(response.generations[0].text)) {
            throw new DNAMSPipelineException('The model returned no transmittal summary.');
        }
        return response.generations[0].text;
    }
}
