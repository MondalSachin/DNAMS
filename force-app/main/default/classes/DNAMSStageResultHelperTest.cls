/**
 * @description     Tests DNAMSStageResultHelper: Classification rows carry the AI answer and outcome; errors are rows
 *                  with Error status and the error text.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-04
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-04   Abhishek Dutta  Initial version
 **/
@IsTest
private class DNAMSStageResultHelperTest {
    /**
     * @description File result as the classification batch fills it.
     * @param title   File title
     * @param outcome Batch outcome constant
     * @return        File result
     **/
    private static DNAMS_DocumentClassificationBatch.FileResult fileResult(String title, String outcome) {
        DNAMS_DocumentClassificationBatch.FileResult result = new DNAMS_DocumentClassificationBatch.FileResult();
        result.title = title;
        result.outcome = outcome;
        result.documentType = 'Utility Bill';
        result.confidence = 'FULLY';
        result.reasoning = outcome == DNAMS_DocumentClassificationBatch.OUTCOME_ERROR ? 'System.CalloutException: model down' : 'A utility bill.';
        result.rawResponse = '{"document_type":"Utility Bill"}';
        return result;
    }

    /**
     * @description A match and an error become two Classification rows, inserted against the run.
     **/
    @IsTest
    static void testClassificationRowsMatchAndError() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMS_Package_Element__c element = [
                SELECT Id, Name, Element_Type__r.Name FROM DNAMS_Package_Element__c
                WHERE Id = :fixture.elementIdByType.get('Address Verification') WITH SYSTEM_MODE
            ];
            List<DNAMS_DocumentClassificationBatch.FileResult> results = new List<DNAMS_DocumentClassificationBatch.FileResult>{
                fileResult('bill.pdf', DNAMS_DocumentClassificationBatch.OUTCOME_MATCH),
                fileResult('broken.pdf', DNAMS_DocumentClassificationBatch.OUTCOME_ERROR)
            };

            Test.startTest();
            DNAMSStageResultHelper.insertRows(DNAMSStageResultHelper.classificationRows(fixture.runId, element, results));
            DNAMSStageResultHelper.insertRows(new List<AIReviewStageResult__c>());
            Test.stopTest();

            Map<String, AIReviewStageResult__c> byTitle = new Map<String, AIReviewStageResult__c>();
            for (AIReviewStageResult__c row : [
                SELECT DocumentTitle__c, Stage__c, ElementType__c, Outcome__c, ProcessingStatus__c, Reasoning__c, ProcessingErrorDetails__c
                FROM AIReviewStageResult__c WHERE ReviewRun__c = :fixture.runId WITH SYSTEM_MODE
            ]) {
                byTitle.put(row.DocumentTitle__c, row);
            }
            Assert.areEqual(2, byTitle.size(), 'One row per file');
            Assert.areEqual('Classification', byTitle.get('bill.pdf').Stage__c, 'Classification stage');
            Assert.areEqual('Address Verification', byTitle.get('bill.pdf').ElementType__c, 'Element type recorded');
            Assert.areEqual('Completed', byTitle.get('bill.pdf').ProcessingStatus__c, 'Match is Completed');
            Assert.areEqual('A utility bill.', byTitle.get('bill.pdf').Reasoning__c, 'Reasoning recorded');
            Assert.areEqual('Error', byTitle.get('broken.pdf').ProcessingStatus__c, 'Error outcome is an Error row');
            Assert.isTrue(byTitle.get('broken.pdf').ProcessingErrorDetails__c.contains('model down'), 'Error text recorded');
        }
    }
}
