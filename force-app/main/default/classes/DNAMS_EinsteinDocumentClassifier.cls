/**
 * Calls the DNAMS_DocumentClassifier_Prompt flex template (inputs: the File and its Package Element)
 * through the Einstein Trust Layer.
 */
public with sharing class DNAMS_EinsteinDocumentClassifier implements DNAMS_DocumentClassifier {
    public String classify(String promptTemplate, Id contentDocumentId, Id elementId) {
        Map<String, ConnectApi.WrappedValue> inputs = new Map<String, ConnectApi.WrappedValue>{
            'Input:document' => wrapRecordId(contentDocumentId),
            'Input:element' => wrapRecordId(elementId)
        };
        ConnectApi.EinsteinPromptTemplateGenerationsInput request = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        request.inputParams = inputs;
        request.isPreview = false;
        request.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        request.additionalConfig.applicationName = 'PromptBuilderPreview';

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
            promptTemplate,
            request
        );
        if (response.generations == null || response.generations.isEmpty()) {
            throw new DNAMS_PackageReviewPipelineService.PipelineException('The model returned no generation.');
        }
        return response.generations[0].text;
    }

    private static ConnectApi.WrappedValue wrapRecordId(Id recordId) {
        ConnectApi.WrappedValue value = new ConnectApi.WrappedValue();
        value.value = new Map<String, String>{ 'id' => recordId };
        return value;
    }
}