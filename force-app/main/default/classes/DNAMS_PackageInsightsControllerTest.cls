/**
 * @description     Tests for DNAMS_PackageInsightsController (record page components) and the structured summary of
 *                  DNAMS_PackageNarrativeQueueable (parse, fallback, plain text, GREEN hand-off).
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-05
 * @last modified by Sachin Mondal
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-05   Sachin Mondal   Initial version
 **/
// Exception to guideline: the DNAMS_ prefix is the project's class naming standard for this module
@SuppressWarnings('PMD.ClassNamingConventions')
@IsTest
private class DNAMS_PackageInsightsControllerTest {
    private class StubWriter implements DNAMS_NarrativeWriter {
        String answer;
        public String write(String promptTemplate, String factsJson) {
            Assert.isTrue(factsJson.contains('"elements"'), 'Facts are sent as JSON');
            return answer;
        }
    }

    private static DNAMSPipelineTestHelper.PipelineFixture fixtureWithResults() {
        DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
        DNAMS_PackageReviewPipelineService.settingsOverride = DNAMSPipelineTestHelper.getPipelineSettings();
        update new List<DNAMS_Package_Element__c>{
            new DNAMS_Package_Element__c(Id = fixture.elementIdByType.get('Dealer Application'), Rule_Validation_Status__c = 'Failed', Element_Narrative__c = 'Rules not met: Dealer Code Match'),
            new DNAMS_Package_Element__c(Id = fixture.elementIdByType.get('Address Verification'), Extraction_Status__c = 'Passed', Rule_Validation_Status__c = 'Needs Review'),
            new DNAMS_Package_Element__c(Id = fixture.elementIdByType.get('Org Chart'), Extraction_Status__c = 'Passed', Rule_Validation_Status__c = 'Passed'),
            new DNAMS_Package_Element__c(Id = fixture.elementIdByType.get('Photographs of Facility'), Extraction_Status__c = 'In Progress')
        };
        return fixture;
    }

    @IsTest
    static void elementProgressCountsElementsAndStages() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = fixtureWithResults();

            DNAMS_PackageInsightsController.ProgressView progress = DNAMS_PackageInsightsController.getElementProgress(fixture.packageId);

            Assert.areEqual(4, progress.total, 'Elements');
            Assert.areEqual(4, progress.required, 'Required');
            Assert.areEqual(4, progress.withDocuments, 'Every fixture element has a file');
            Assert.areEqual(2, progress.failed, 'Dealer Application failed; Address Verification needs review counts as failed');
            Assert.areEqual(2, progress.passed, 'Org Chart and Photographs of Facility (classification passed)');
            Assert.areEqual(0, progress.notReviewed, 'Every element has a result');
            Assert.areEqual(3, progress.stages.size(), 'Classification, Extraction and Rule Validation (no Transmittal)');
            DNAMS_PackageInsightsController.StageCount classification = progress.stages[0];
            Assert.areEqual('All Documents Present', classification.label, 'Business name shown');
            Assert.areEqual('Is Document Valid and Complete', progress.stages[2].label, 'Business name shown');
            Assert.areEqual(4, classification.passed, 'The fixture marks every element classified');
            DNAMS_PackageInsightsController.StageCount ruleValidation = progress.stages[2];
            Assert.areEqual(2, ruleValidation.failed, 'Failed and needs review are both failed');
            Assert.areEqual(1, ruleValidation.passed, 'Rule validation passed');
            Assert.areEqual(1, ruleValidation.notRun, 'Not run yet');
        }
    }

    @IsTest
    static void documentsAreGroupedByElement() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = fixtureWithResults();

            List<DNAMS_PackageInsightsController.ElementFiles> groups = DNAMS_PackageInsightsController.getDocuments(fixture.packageId);

            Assert.areEqual(4, groups.size(), 'One group per required element');
            Map<String, DNAMS_PackageInsightsController.ElementFiles> byName = new Map<String, DNAMS_PackageInsightsController.ElementFiles>();
            for (DNAMS_PackageInsightsController.ElementFiles elementFiles : groups) {
                byName.put(elementFiles.name, elementFiles);
            }
            Assert.areEqual(2, byName.get('Address Verification').files.size(), 'Form and utility bill on one element');
            DNAMS_PackageInsightsController.FileView file = byName.get('Org Chart').files[0];
            Assert.areEqual('Org Chart', file.classifiedAs, 'Classification shown');
            Assert.areEqual('pdf', file.extension, 'Extension');
            Assert.isNotNull(file.contentDocumentId, 'Preview id');
            Assert.areEqual('Failed', byName.get('Dealer Application').status, 'Element status');
        }
    }

    @IsTest
    static void aiSummaryReturnsStructureAndLatestRun() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = fixtureWithResults();
            update new DNAMS_Package__c(Id = fixture.packageId, Health__c = 'Amber', AI_Narrative_JSON__c = '{"headline":"x"}', AI_Narrative__c = 'x');

            DNAMS_PackageInsightsController.SummaryView view = DNAMS_PackageInsightsController.getAiSummary(fixture.packageId);

            Assert.areEqual('Amber', view.health, 'Health');
            Assert.areEqual('{"headline":"x"}', view.summaryJson, 'Structured summary');
            Assert.areEqual(fixture.runId, view.runId, 'Latest run');
            Assert.areEqual(DNAMS_PackageNarrativeQueueable.AI_LABEL, view.aiLabel, 'AI label always returned');
        }
    }

    @IsTest
    static void greenRunGetsASummaryThenMovesOn() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = fixtureWithResults();
            update new DNAMS_Package__c(Id = fixture.packageId, Health__c = 'Green');
            StubWriter stub = new StubWriter();
            stub.answer = '{"headline": "All checks passed", "summary": "Everything matched.", "elements": [], "next_steps": ["Proceed."]}';
            DNAMS_PackageNarrativeQueueable.writer = stub;

            new DNAMS_PackageNarrativeQueueable(fixture.runId, 'rule validation GREEN', new DNAMSTransmittalStarterQueueable(fixture.runId)).execute(null);

            DNAMS_Package__c pkg = [SELECT AI_Narrative__c, AI_Narrative_JSON__c FROM DNAMS_Package__c WHERE Id = :fixture.packageId];
            Assert.isTrue(pkg.AI_Narrative__c.startsWith('All checks passed [GREEN]'), pkg.AI_Narrative__c);
            Assert.isTrue(pkg.AI_Narrative_JSON__c.contains('"overall_health":"GREEN"'), pkg.AI_Narrative_JSON__c);
            Assert.areEqual(1, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'DNAMSTransmittalStarterQueueable'], 'Transmittal queued after the summary');
        }
    }

    @IsTest
    static void outOfShapeAnswerFallsBackToTheSameStructure() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = fixtureWithResults();
            update new DNAMS_Package__c(Id = fixture.packageId, Health__c = 'Red');
            StubWriter stub = new StubWriter();
            stub.answer = 'Sorry, I cannot help with that.';
            DNAMS_PackageNarrativeQueueable.writer = stub;

            new DNAMS_PackageNarrativeQueueable(fixture.runId).execute(null);

            Map<String, Object> summary = (Map<String, Object>) JSON.deserializeUntyped(
                [SELECT AI_Narrative_JSON__c FROM DNAMS_Package__c WHERE Id = :fixture.packageId].AI_Narrative_JSON__c
            );
            Assert.areEqual('RED', summary.get('overall_health'), 'Health from the package');
            List<Object> elements = (List<Object>) summary.get('elements');
            Assert.areEqual(3, elements.size(), 'Failed, needs review and in progress elements are listed');
            Assert.isTrue([SELECT Error__c FROM AI_Package_Review_Run__c WHERE Id = :fixture.runId].Error__c.contains('fell back'), 'Fallback recorded');
        }
    }

    @IsTest
    static void summaryHelpers() {
        try {
            DNAMS_PackageNarrativeQueueable.parseSummary('{"summary": "no headline"}');
            Assert.fail('A headline is required');
        } catch (DNAMSPipelineException expected) {
            Assert.isTrue(expected.getMessage().contains('headline'), expected.getMessage());
        }
        Map<String, Object> parsed = DNAMS_PackageNarrativeQueueable.parseSummary(
            '{"headline": "H", "elements": [{"element": "Org Chart", "status": "weird", "findings": ["a", "", "b"]}, "skip"]}'
        );
        Map<String, Object> element = (Map<String, Object>) ((List<Object>) parsed.get('elements'))[0];
        Assert.areEqual('NEEDS_REVIEW', element.get('status'), 'Unknown status normalised');
        Assert.areEqual(2, ((List<Object>) element.get('findings')).size(), 'Blank findings dropped');

        Map<String, Object> clean = DNAMS_PackageNarrativeQueueable.fallbackSummary(new Map<String, Object>{ 'elements' => new List<Object>() });
        Assert.areEqual('All checks passed', clean.get('headline'), 'Clean fallback');
        clean.put('overall_health', 'GREEN');
        String plain = DNAMS_PackageNarrativeQueueable.toPlainText(clean);
        Assert.isTrue(plain.contains('Next steps:'), plain);

        Assert.areEqual('MISSING', DNAMS_PackageNarrativeQueueable.elementStatus(new DNAMS_Package_Element__c(Is_Required__c = true), false), 'Required without file');
        Assert.areEqual('Not Reviewed', DNAMS_PackageInsightsController.overallStatus(new DNAMS_Package_Element__c()), 'No stage yet');
    }
}
