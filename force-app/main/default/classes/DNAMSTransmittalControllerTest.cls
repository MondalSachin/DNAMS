/**
 * @description     Tests for DNAMSTransmittalController: every Draft AI Transmittal scenario, refusal to draft in the
 *                  info-only scenarios, and the draft paths with the Transmittal Draft Source each one records. The model
 *                  is stubbed through DNAMSTransmittalSummaryService.ai, so no prompt template is invoked.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-05
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-05   Abhishek Dutta  Initial version
 **/
@IsTest
private class DNAMSTransmittalControllerTest {
    private static final String STUB_ANSWER = '{"lines":["Line one.","Line two."]}';

    /**
     * @description Model stub: returns STUB_ANSWER, or throws when fail is set.
     **/
    private class StubTransmittalAI implements DNAMSTransmittalAI {
        Boolean fail = false;
        Integer calls = 0;

        /**
         * @description Returns the canned answer or throws.
         * @param promptTemplate Prompt template API name (unused)
         * @param contextJson    Context JSON (unused)
         * @return STUB_ANSWER
         **/
        public String generate(String promptTemplate, String contextJson) {
            calls++;
            if (fail) {
                throw new DNAMSPipelineException('model unavailable');
            }
            return STUB_ANSWER;
        }
    }

    // ------------------------------------------------------------------ fixture helpers

    /**
     * @description Extraction fixture plus transmittal settings and the model stub.
     * @param stub The model stub to inject
     * @return The fixture
     **/
    private static DNAMSPipelineTestHelper.PipelineFixture setUp(StubTransmittalAI stub) {
        DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
        DNAMS_Pipeline_Setting__mdt settings = DNAMSPipelineTestHelper.getPipelineSettings();
        settings.OwnershipSummaryPromptTemplate__c = 'DNAMS_OwnershipSummary_Prompt';
        settings.ExecutiveSummaryPromptTemplate__c = 'DNAMS_ExecutiveSummary_Prompt';
        settings.TransmittalMaxAttempts__c = 1;
        settings.TransmittalSummaryMaxWords__c = 50;
        DNAMS_PackageReviewPipelineService.settingsOverride = settings;
        DNAMSTransmittalSummaryService.ai = stub;
        return fixture;
    }

    /**
     * @description Marks every review stage Completed and sets the transmittal status.
     * @param fixture           The fixture
     * @param transmittalStatus TransmittalProcessingStatus__c value, or null
     **/
    private static void completeReview(DNAMSPipelineTestHelper.PipelineFixture fixture, String transmittalStatus) {
        update new AI_Package_Review_Run__c(
            Id = fixture.runId,
            Classification_Processing_Status__c = DNAMSPipelineConstants.RUN_STAGE_COMPLETED,
            ExtractionProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_COMPLETED,
            RuleValidationProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_COMPLETED,
            TransmittalProcessingStatus__c = transmittalStatus
        );
    }

    /**
     * @description Inserts one passing and one failing rule validation row on the fixture run.
     * @param fixture The fixture
     **/
    private static void addRuleRows(DNAMSPipelineTestHelper.PipelineFixture fixture) {
        insert new List<AIReviewStageResult__c>{
            ruleRow(fixture, 'V1', DNAMSPipelineConstants.VERDICT_PASS),
            ruleRow(fixture, 'V2', DNAMSPipelineConstants.VERDICT_FAIL)
        };
    }

    /**
     * @description A completed rule validation row (no DML).
     * @param fixture The fixture
     * @param ruleId  Rule id
     * @param verdict Verdict__c value
     * @return The unsaved row
     **/
    private static AIReviewStageResult__c ruleRow(DNAMSPipelineTestHelper.PipelineFixture fixture, String ruleId, String verdict) {
        return new AIReviewStageResult__c(
            ReviewRun__c = fixture.runId,
            Stage__c = DNAMSPipelineConstants.STAGE_RULE_VALIDATION,
            RuleId__c = ruleId,
            RuleName__c = 'Rule ' + ruleId,
            Verdict__c = verdict,
            ProcessingStatus__c = DNAMSPipelineConstants.ROW_COMPLETED
        );
    }

    /**
     * @description Reloads the package transmittal fields.
     * @param fixture The fixture
     * @return The package
     **/
    private static DNAMS_Package__c reloadPackage(DNAMSPipelineTestHelper.PipelineFixture fixture) {
        return [
            SELECT Ownership_Summary__c, Executive_Summary__c, Transmittal_Drafted_At__c, Transmittal_Draft_Source__c
            FROM DNAMS_Package__c
            WHERE Id = :fixture.packageId
        ];
    }

    /**
     * @description Transmittal stage rows of the fixture run.
     * @param fixture The fixture
     * @return The rows
     **/
    private static List<AIReviewStageResult__c> transmittalRows(DNAMSPipelineTestHelper.PipelineFixture fixture) {
        return [
            SELECT SummaryType__c, Outcome__c, RequestedBy__c, ProcessingStatus__c
            FROM AIReviewStageResult__c
            WHERE ReviewRun__c = :fixture.runId AND Stage__c = :DNAMSPipelineConstants.STAGE_TRANSMITTAL
        ];
    }

    /**
     * @description Asserts drafting was refused with the scenario message and nothing was written.
     * @param fixture         The fixture
     * @param stub            The model stub
     * @param expectedMessage The scenario message
     **/
    private static void assertRefused(DNAMSPipelineTestHelper.PipelineFixture fixture, StubTransmittalAI stub, String expectedMessage) {
        Test.startTest();
        DNAMSTransmittalController.DraftOutcome outcome = DNAMSTransmittalController.draftTransmittal(fixture.packageId);
        Test.stopTest();
        Assert.isFalse(outcome.success, 'Info-only scenario must not draft');
        Assert.areEqual(expectedMessage, outcome.message, 'Scenario message returned');
        Assert.areEqual(0, stub.calls, 'Model not called');
        Assert.isNull(reloadPackage(fixture).Transmittal_Draft_Source__c, 'Package not drafted');
        Assert.isTrue(transmittalRows(fixture).isEmpty(), 'No transmittal rows');
    }

    /**
     * @description Drafts and asserts the success outcome, package fields and stage rows for a draft source.
     * @param fixture        The fixture
     * @param expectedSource Expected Transmittal_Draft_Source__c
     **/
    private static void assertDrafted(DNAMSPipelineTestHelper.PipelineFixture fixture, String expectedSource) {
        Test.startTest();
        DNAMSTransmittalController.DraftOutcome outcome = DNAMSTransmittalController.draftTransmittal(fixture.packageId);
        Test.stopTest();
        Assert.isTrue(outcome.success, 'Drafted: ' + outcome.message);
        Assert.areEqual(DNAMSTransmittalController.MESSAGE_DRAFT_SUCCESS, outcome.message, 'Success message');
        DNAMS_Package__c packageObj = reloadPackage(fixture);
        Assert.areEqual(expectedSource, packageObj.Transmittal_Draft_Source__c, 'Draft source');
        Assert.isTrue(packageObj.Ownership_Summary__c.contains('Line one.'), packageObj.Ownership_Summary__c);
        Assert.isTrue(packageObj.Executive_Summary__c.contains('Line two.'), packageObj.Executive_Summary__c);
        Assert.isNotNull(packageObj.Transmittal_Drafted_At__c, 'Drafted at stamped');
        List<AIReviewStageResult__c> rows = transmittalRows(fixture);
        Assert.areEqual(2, rows.size(), 'One row per summary');
        for (AIReviewStageResult__c row : rows) {
            Assert.areEqual(expectedSource, row.Outcome__c, 'Row outcome is the draft source');
            Assert.areEqual(UserInfo.getUserId(), row.RequestedBy__c, 'Requested by the RMR');
        }
    }

    // ------------------------------------------------------------------ scenarios

    @IsTest
    static void noRunWhenOnlyRunIsDiscarded() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            StubTransmittalAI stub = new StubTransmittalAI();
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUp(stub);
            update new AI_Package_Review_Run__c(Id = fixture.runId, Status__c = DNAMS_PackageReviewPipelineService.RUN_DISCARDED);

            DNAMSTransmittalController.DraftState state = DNAMSTransmittalController.getDraftState(fixture.packageId);
            Assert.areEqual(DNAMSTransmittalController.SCENARIO_NO_RUN, state.scenario, 'Discarded runs are ignored');
            Assert.areEqual(DNAMSTransmittalController.MESSAGE_NO_RUN, state.message, 'No run message');
            Assert.isNull(state.runId, 'No run id');
            assertRefused(fixture, stub, DNAMSTransmittalController.MESSAGE_NO_RUN);
        }
    }

    @IsTest
    static void inProgressWhileExtractionPending() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            StubTransmittalAI stub = new StubTransmittalAI();
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUp(stub);

            DNAMSTransmittalController.DraftState state = DNAMSTransmittalController.getDraftState(fixture.packageId);
            Assert.areEqual(DNAMSTransmittalController.SCENARIO_IN_PROGRESS, state.scenario, 'Extraction still pending');
            Assert.areEqual(fixture.runId, state.runId, 'Latest run');
            assertRefused(fixture, stub, DNAMSTransmittalController.MESSAGE_IN_PROGRESS);
        }
    }

    @IsTest
    static void inProgressWhenRuleValidationFailed() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUp(new StubTransmittalAI());
            completeReview(fixture, null);
            update new AI_Package_Review_Run__c(Id = fixture.runId, RuleValidationProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_FAILED);

            DNAMSTransmittalController.DraftState state = DNAMSTransmittalController.getDraftState(fixture.packageId);
            Assert.areEqual(DNAMSTransmittalController.SCENARIO_IN_PROGRESS, state.scenario, 'A stage that is not Completed blocks drafting');
            Assert.areEqual(DNAMSTransmittalController.MESSAGE_IN_PROGRESS, state.message, 'In progress message');
        }
    }

    @IsTest
    static void draftingWhileTransmittalPending() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            StubTransmittalAI stub = new StubTransmittalAI();
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUp(stub);
            completeReview(fixture, DNAMSPipelineConstants.RUN_STAGE_PENDING);

            DNAMSTransmittalController.DraftState state = DNAMSTransmittalController.getDraftState(fixture.packageId);
            Assert.areEqual(DNAMSTransmittalController.SCENARIO_DRAFTING, state.scenario, 'Auto draft queued');
            Assert.areEqual(DNAMSTransmittalController.MESSAGE_DRAFTING, state.message, 'Drafting message');
            assertRefused(fixture, stub, DNAMSTransmittalController.MESSAGE_DRAFTING);
        }
    }

    @IsTest
    static void draftedRedraftsAsRmrRedraft() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUp(new StubTransmittalAI());
            completeReview(fixture, DNAMSPipelineConstants.RUN_STAGE_COMPLETED);
            addRuleRows(fixture);

            DNAMSTransmittalController.DraftState state = DNAMSTransmittalController.getDraftState(fixture.packageId);
            Assert.areEqual(DNAMSTransmittalController.SCENARIO_DRAFTED, state.scenario, 'Drafted wins over failing rules');
            Assert.areEqual(DNAMSTransmittalController.MESSAGE_DRAFTED, state.message, 'Redraft question');
            assertDrafted(fixture, DNAMSPipelineConstants.DRAFT_SOURCE_RMR_REDRAFT);
        }
    }

    @IsTest
    static void rulesFailedDraftsAsRmrOverride() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUp(new StubTransmittalAI());
            completeReview(fixture, null);
            addRuleRows(fixture);

            DNAMSTransmittalController.DraftState state = DNAMSTransmittalController.getDraftState(fixture.packageId);
            Assert.areEqual(DNAMSTransmittalController.SCENARIO_RULES_FAILED, state.scenario, 'One rule failed');
            Assert.areEqual(1, state.failingRuleCount, 'Failing rule count');
            Assert.isTrue(state.message.contains('(1 failing rule(s))'), state.message);
            assertDrafted(fixture, DNAMSPipelineConstants.DRAFT_SOURCE_RMR_OVERRIDE);
        }
    }

    @IsTest
    static void readyDraftsAsRmrDraft() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUp(new StubTransmittalAI());
            completeReview(fixture, DNAMSPipelineConstants.RUN_STAGE_FAILED);

            DNAMSTransmittalController.DraftState state = DNAMSTransmittalController.getDraftState(fixture.packageId);
            Assert.areEqual(DNAMSTransmittalController.SCENARIO_READY, state.scenario, 'Auto draft failed, rules passed');
            Assert.areEqual(0, state.failingRuleCount, 'No failing rules');
            Assert.areEqual(DNAMSTransmittalController.MESSAGE_READY, state.message, 'Ready question');
            assertDrafted(fixture, DNAMSPipelineConstants.DRAFT_SOURCE_RMR_DRAFT);
        }
    }

    @IsTest
    static void modelFailureReturnsServiceMessage() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            StubTransmittalAI stub = new StubTransmittalAI();
            stub.fail = true;
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUp(stub);
            completeReview(fixture, null);

            Test.startTest();
            DNAMSTransmittalController.DraftOutcome outcome = DNAMSTransmittalController.draftTransmittal(fixture.packageId);
            Test.stopTest();

            Assert.isFalse(outcome.success, 'Model failure is not a success');
            Assert.isTrue(String.isNotBlank(outcome.message), 'Service message returned');
            Assert.areNotEqual(DNAMSTransmittalController.MESSAGE_DRAFT_SUCCESS, outcome.message, 'Not the success message');
            Assert.isNull(reloadPackage(fixture).Transmittal_Draft_Source__c, 'Package not drafted');
        }
    }

    @IsTest
    static void missingPackageIsRejected() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            try {
                DNAMSTransmittalController.getDraftState(null);
                Assert.fail('A missing package must be rejected');
            } catch (AuraHandledException e) {
                Assert.areEqual(DNAMSTransmittalController.MESSAGE_NO_ACCESS, e.getMessage(), 'User-safe message');
            }
        }
    }
}
