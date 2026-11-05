/**
 * Calls the narrator prompt template with the run's facts (JSON text input "facts") and returns the model's answer,
 * which should be the structured summary JSON (see DNAMS_PackageNarrativeQueueable).
 */
public with sharing class DNAMS_EinsteinNarrativeWriter implements DNAMS_NarrativeWriter {
    public String write(String promptTemplate, String factsJson) {
        ConnectApi.WrappedValue facts = new ConnectApi.WrappedValue();
        facts.value = factsJson;
        ConnectApi.EinsteinPromptTemplateGenerationsInput request = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        request.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:facts' => facts };
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
