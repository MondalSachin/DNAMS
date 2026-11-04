/**
 * Calls the DNAMS_PackageIssueNarrator_Prompt flex template (input: the review run) through the Einstein Trust Layer.
 */
public with sharing class DNAMS_EinsteinNarrativeWriter implements DNAMS_NarrativeWriter {
    public String write(String promptTemplate, Id runId) {
        ConnectApi.WrappedValue run = new ConnectApi.WrappedValue();
        run.value = new Map<String, String>{ 'id' => runId };
        ConnectApi.EinsteinPromptTemplateGenerationsInput request = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        request.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:run' => run };
        request.isPreview = false;
        request.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        request.additionalConfig.applicationName = 'PromptBuilderPreview';

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
            promptTemplate,
            request
        );
        if (response.generations == null || response.generations.isEmpty() || String.isBlank(response.generations[0].text)) {
            throw new DNAMS_PackageReviewPipelineService.PipelineException('The model returned no narrative.');
        }
        return response.generations[0].text.trim();
    }
}