/**
 * @description     Tests DNAMSIDPEventTrigger and DNAMSIDPEventTriggerHandler: event routing, one job per type per
 *                  invocation, and unknown events ignored.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-05
 * @last modified by Abhishek Dutta
 * @last modification details Counts the callback processor queued by the stub-mode callback simulation
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 * 1.1   2026-11-05   Abhishek Dutta  Counts the callback processor queued by the stub-mode callback simulation
 **/
@IsTest
private class DNAMSIDPEventTriggerHandlerTest {
    /**
     * @description Counts queued Queueable jobs of one class.
     * @param className Apex class name
     * @return          Number of jobs
     **/
    private static Integer countQueueables(String className) {
        return [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable' AND ApexClass.Name = :className];
    }

    @IsTest
    static void testHandleEventsMixedBatchEnqueuesOneJobPerType() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_STUB);
            // Completed: the submit batch started by the starter leaves it alone, so only the callback could change it
            AIReviewStageResult__c settledRow = DNAMSExtractionPipelineTest.insertRow(fixture, 'Org Chart', DNAMSPipelineConstants.ROW_COMPLETED);
            List<DNAMSIDPEvent__e> events = new List<DNAMSIDPEvent__e>{
                new DNAMSIDPEvent__e(EventType__c = DNAMSPipelineConstants.EVENT_START_EXTRACTION, ReviewRunId__c = fixture.runId),
                new DNAMSIDPEvent__e(EventType__c = DNAMSPipelineConstants.EVENT_START_EXTRACTION, ReviewRunId__c = fixture.runId),
                new DNAMSIDPEvent__e(EventType__c = DNAMSPipelineConstants.EVENT_CALLBACK, ReviewRunId__c = fixture.runId, StageResultId__c = settledRow.Id)
            };

            Test.startTest();
            DNAMSIDPEventTriggerHandler.handleEvents(events);
            Test.stopTest();

            Assert.areEqual(1, countQueueables(DNAMSExtractionStarterQueueable.class.getName()), 'Start events share one starter');
            // The handled Callback event queues one processor; the stub-mode submit batch run by the starter queues a second
            // one for the callback it simulates (DNAMSExtractionSubmitBatch.simulateStubCallbacks).
            Assert.areEqual(2, countQueueables(DNAMSIDPCallbackQueueable.class.getName()), 'Callback events share one processor per delivery');
            Assert.areEqual(
                DNAMSPipelineConstants.RUN_STAGE_IN_PROGRESS,
                DNAMSExtractionPipelineTest.reloadRun(fixture.runId).ExtractionProcessingStatus__c,
                'The starter ran for the run'
            );
            Assert.areEqual(
                DNAMSPipelineConstants.ROW_COMPLETED,
                [SELECT ProcessingStatus__c FROM AIReviewStageResult__c WHERE Id = :settledRow.Id].ProcessingStatus__c,
                'A callback for a row that is not In Progress is ignored'
            );
        }
    }

    @IsTest
    static void testTriggerPublishedStartEventStartsExtraction() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMSExtractionPipelineTest.useSettings(DNAMSPipelineConstants.IDP_MODE_STUB);

            Test.startTest();
            EventBus.publish(new DNAMSIDPEvent__e(EventType__c = DNAMSPipelineConstants.EVENT_START_EXTRACTION, ReviewRunId__c = fixture.runId));
            Test.getEventBus().deliver();
            Test.stopTest();

            Assert.areEqual(
                DNAMSPipelineTestHelper.ELEMENT_TYPE_BY_DOCUMENT_TYPE.size(),
                DNAMSExtractionPipelineTest.rowsByDocumentType(fixture.runId).size(),
                'The trigger routed the event to the starter, which created one row per file'
            );
        }
    }

    @IsTest
    static void testHandleEventsUnknownOrBlankEventsEnqueueNothing() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            List<DNAMSIDPEvent__e> events = new List<DNAMSIDPEvent__e>{
                new DNAMSIDPEvent__e(EventType__c = 'Something Else', ReviewRunId__c = fixture.runId),
                new DNAMSIDPEvent__e(EventType__c = DNAMSPipelineConstants.EVENT_CALLBACK)
            };

            Test.startTest();
            DNAMSIDPEventTriggerHandler.handleEvents(events);
            Test.stopTest();

            Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable'], 'No job for unknown or incomplete events');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_PENDING, DNAMSExtractionPipelineTest.reloadRun(fixture.runId).ExtractionProcessingStatus__c, 'ExtractionProcessingStatus__c has the expected value');
        }
    }
}
