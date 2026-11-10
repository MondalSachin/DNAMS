/**
 * @description     Tests for "Re-run changes only" in rule validation, the AI summary (narrative) and automatic
 *                  transmittal drafting: DNAMSRuleValidationStarterQueueable (AIMatch reuse), DNAMSRuleValidationCompletionHelper,
 *                  DNAMS_PackageNarrativeQueueable and DNAMSTransmittalStarterQueueable (keep or redraft). Rules are injected
 *                  in memory and every model is stubbed.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-10
 * @last modified by Abhishek Dutta
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-10   Abhishek Dutta  Initial version
 **/
@IsTest
private class DNAMSRerunRuleTest {
    private static final String DEALER_CODE = 'TCE00087';
    private static final String DA = 'Dealer Application';
    private static final String NARRATIVE_JSON_MARKER = 'Baseline headline';

    /**
     * @description AIMatch validator stub: every rule passes; counts calls.
     **/
    private class StubValidator implements DNAMSRuleAIValidator {
        Integer calls = 0;

        /**
         * @description Answers PASS for every comparison sent.
         * @param promptTemplate  Prompt template name (unused)
         * @param comparisonsJson Comparisons sent to the model
         * @return                JSON array of verdicts
         **/
        public String validate(String promptTemplate, String comparisonsJson) {
            calls++;
            List<Object> answers = new List<Object>();
            for (Object item : (List<Object>) JSON.deserializeUntyped(comparisonsJson)) {
                Map<String, Object> comparison = (Map<String, Object>) item;
                answers.add(new Map<String, Object>{ 'rule_id' => comparison.get('rule_id'), 'verdict' => 'PASS', 'reasoning' => 'Same entity.' });
            }
            return JSON.serialize(answers);
        }
    }

    /**
     * @description Narrative writer stub; counts calls.
     **/
    private class StubWriter implements DNAMS_NarrativeWriter {
        Integer calls = 0;

        /**
         * @description Returns a fixed summary JSON.
         * @param promptTemplate Prompt template name (unused)
         * @param factsJson      Run facts (unused)
         * @return               Summary JSON
         **/
        public String write(String promptTemplate, String factsJson) {
            calls++;
            return '{"headline": "' + NARRATIVE_JSON_MARKER + ' ' + calls + '", "summary": "Call ' + calls + '.", "elements": [], "next_steps": []}';
        }
    }

    /**
     * @description Transmittal model stub; counts calls.
     **/
    private class StubTransmittalAI implements DNAMSTransmittalAI {
        Integer calls = 0;

        /**
         * @description Returns one summary line.
         * @param promptTemplate Prompt template name (unused)
         * @param contextJson    Context (unused)
         * @return               {"lines": [...]}
         **/
        public String generate(String promptTemplate, String contextJson) {
            calls++;
            return '{"lines": ["Summary line ' + calls + '."]}';
        }
    }

    /**
     * @description All stubs used by one test.
     **/
    private class Stubs {
        StubValidator validator = new StubValidator();
        StubWriter writer = new StubWriter();
        StubTransmittalAI transmittal = new StubTransmittalAI();

        /**
         * @description Installs the stubs.
         **/
        Stubs() {
            DNAMSAIRuleValidationQueueable.validator = validator;
            DNAMS_PackageNarrativeQueueable.writer = writer;
            DNAMSTransmittalSummaryService.ai = transmittal;
        }
    }

    // ------------------------------------------------------------------ fixture helpers

    private static DNAMSPipelineTestHelper.PipelineFixture setUpBaseline() {
        DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
        DNAMS_Pipeline_Setting__mdt settings = DNAMSPipelineTestHelper.getPipelineSettings();
        settings.RuleValidationBatchSize__c = 50;
        settings.RuleValidationPromptTemplate__c = 'DNAMS_RuleValidation_Prompt';
        settings.PIRRequiredPackageTypes__c = 'Buy/Sell change of Ownership;Dealer Principal Change';
        settings.OwnershipSummaryPromptTemplate__c = 'DNAMS_OwnershipSummary_Prompt';
        settings.ExecutiveSummaryPromptTemplate__c = 'DNAMS_ExecutiveSummary_Prompt';
        settings.TransmittalMaxAttempts__c = 1;
        settings.Max_Attempts__c = 1;
        DNAMS_PackageReviewPipelineService.settingsOverride = settings;
        update new AI_Package_Review_Run__c(
            Id = fixture.runId,
            ExtractionProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_COMPLETED,
            ConsolidatedExtractionJSON__c = consolidatedJson()
        );
        return fixture;
    }

    private static String consolidatedJson() {
        Map<String, Object> dealerApplication = new Map<String, Object>{
            'DealerCode' => DEALER_CODE,
            'LegalNameOrDealerEntity' => 'dnams  TEST dealer'
        };
        return JSON.serialize(new Map<String, Object>{
            'DealerApplication' => new List<Object>{ new Map<String, Object>{ 'elementType' => DA, 'data' => dealerApplication } }
        });
    }

    private static DNAMSRule__mdt rule(String id, String method, String sourceKey, String referenceType, String referenceKey) {
        return new DNAMSRule__mdt(
            DeveloperName = id,
            MasterLabel = 'Rule ' + id,
            Description__c = 'Test rule ' + id,
            RuleType__c = 'Validation',
            ValidationMethod__c = method,
            RuleAppliedTo__c = 'Element',
            RelativeElementType__c = DA,
            SourceFieldType__c = 'Extraction',
            SourceFieldKey__c = sourceKey,
            Comparator__c = 'EQUALS',
            ReferenceFieldType__c = referenceType,
            ReferenceFieldKey__c = referenceKey,
            IsActive__c = true
        );
    }

    /** ExactMatch dealer code vs the buying dealer's AccountNumber, and AIMatch legal name vs the buying dealer's Name. */
    private static void useRules() {
        DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>{
            rule('V1', 'ExactMatch', 'extraction.DealerApplication.DealerCode', 'Record', 'Package.Buying_Dealer__r.AccountNumber'),
            rule('A1', 'AIMatch', 'extraction.DealerApplication.LegalNameOrDealerEntity', 'Record', 'Package.Buying_Dealer__r.Name')
        };
    }

    /** Runs rule validation, the narrative and (GREEN) transmittal drafting the way the queued jobs would. */
    private static void runReview(Id runId) {
        new DNAMSRuleValidationStarterQueueable(runId).execute(null);
        if (reloadRun(runId).RuleValidationProcessingStatus__c != DNAMSPipelineConstants.RUN_STAGE_COMPLETED) {
            new DNAMSAIRuleValidationQueueable(runId).execute(null);
        }
        new DNAMS_PackageNarrativeQueueable(runId, 'test', null).execute(null);
        if (reloadRun(runId).Status__c == DNAMS_PackageReviewPipelineService.RUN_RUNNING) {
            new DNAMSTransmittalStarterQueueable(runId).execute(null);
        }
    }

    private static Id newRun(DNAMSPipelineTestHelper.PipelineFixture fixture, String mode) {
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(
            Package__c = fixture.packageId,
            Status__c = DNAMS_PackageReviewPipelineService.RUN_RUNNING,
            Trigger_Source__c = DNAMS_PackageReviewPipelineService.SOURCE_DEALER_SUBMIT,
            Classification_Processing_Status__c = 'Completed',
            ExtractionProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_COMPLETED,
            ConsolidatedExtractionJSON__c = consolidatedJson(),
            RerunMode__c = mode,
            BaselineRun__c = mode == DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY ? fixture.runId : null,
            Started_At__c = System.now()
        );
        insert run;
        return run.Id;
    }

    private static AI_Package_Review_Run__c reloadRun(Id runId) {
        return [
            SELECT Name, Status__c, Overall_Result__c, Issue_Summary__c, RuleValidationProcessingStatus__c, RuleValidationPassRate__c,
                AIMatchPassRate__c, ChangeSummary__c, TransmittalProcessingStatus__c, Package__r.Health__c, Package__r.Status__c,
                Package__r.AI_Narrative_JSON__c, Package__r.Ownership_Summary__c, Package__r.Executive_Summary__c
            FROM AI_Package_Review_Run__c
            WHERE Id = :runId
        ];
    }

    private static Map<String, AIReviewStageResult__c> rowsByRuleId(Id runId) {
        Map<String, AIReviewStageResult__c> rows = new Map<String, AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : [
            SELECT RuleId__c, Verdict__c, ProcessingStatus__c, ReusedFromResult__c, PackageElement__c, ComparisonMethod__c
            FROM AIReviewStageResult__c
            WHERE ReviewRun__c = :runId AND Stage__c = :DNAMSPipelineConstants.STAGE_RULE_VALIDATION
        ]) {
            rows.put(row.RuleId__c, row);
        }
        return rows;
    }

    private static String ruleStatus(DNAMSPipelineTestHelper.PipelineFixture fixture) {
        return [SELECT Rule_Validation_Status__c FROM DNAMS_Package_Element__c WHERE Id = :fixture.elementIdByType.get(DA)].Rule_Validation_Status__c;
    }

    // ------------------------------------------------------------------ tests

    @IsTest
    static void unchangedValuesReuseAiVerdictAndKeepSummaries() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpBaseline();
            useRules();
            Stubs stubs = new Stubs();
            runReview(fixture.runId);
            AI_Package_Review_Run__c baseline = reloadRun(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.HEALTH_GREEN, baseline.Package__r.Health__c, 'Baseline is GREEN');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, baseline.TransmittalProcessingStatus__c, 'Baseline drafted');
            Assert.areEqual(1, stubs.validator.calls, 'Baseline judged A1');
            Map<String, AIReviewStageResult__c> baselineRows = rowsByRuleId(fixture.runId);

            Id runId = newRun(fixture, DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY);
            new DNAMSRuleValidationStarterQueueable(runId).execute(null);

            Map<String, AIReviewStageResult__c> rows = rowsByRuleId(runId);
            Assert.areEqual(1, stubs.validator.calls, 'Reused AIMatch verdict: no model call');
            Assert.areEqual(baselineRows.get('A1').Id, rows.get('A1').ReusedFromResult__c, 'A1 copied from the baseline');
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_PASS, rows.get('A1').Verdict__c, 'Verdict copied');
            Assert.areEqual(fixture.elementIdByType.get(DA), rows.get('A1').PackageElement__c, 'Linked to the element');
            Assert.isNull(rows.get('V1').ReusedFromResult__c, 'ExactMatch always evaluated');
            Assert.isNull(rows.get('PIR').ReusedFromResult__c, 'PIR always evaluated');

            AI_Package_Review_Run__c run = reloadRun(runId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, run.RuleValidationProcessingStatus__c, 'Nothing pending: completed at once');
            Assert.areEqual(baseline.RuleValidationPassRate__c, run.RuleValidationPassRate__c, 'Pass rate as the full run');
            Assert.areEqual(baseline.AIMatchPassRate__c, run.AIMatchPassRate__c, 'Reused rows count in the AIMatch rate');
            Assert.areEqual(DNAMSPipelineConstants.HEALTH_GREEN, run.Package__r.Health__c, 'Health as the full run');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.STAGE_PASSED, ruleStatus(fixture), 'Element status as the full run');
            Assert.isTrue(run.ChangeSummary__c.contains('Rule Validation: 1 reused, 0 re-checked, 2 exact/PIR evaluated'), run.ChangeSummary__c);
            Assert.isNotNull(run.Package__r.AI_Narrative_JSON__c, 'GREEN does not clear the narrative on a Changes Only run');

            new DNAMS_PackageNarrativeQueueable(runId, 'test', null).execute(null);
            new DNAMSTransmittalStarterQueueable(runId).execute(null);

            run = reloadRun(runId);
            Assert.areEqual(1, stubs.writer.calls, 'Narrative kept: no model call');
            Assert.areEqual(2, stubs.transmittal.calls, 'Summaries kept: no model call (2 from the baseline)');
            Assert.areEqual(baseline.Package__r.AI_Narrative_JSON__c, run.Package__r.AI_Narrative_JSON__c, 'Narrative unchanged');
            Assert.areEqual(baseline.Package__r.Ownership_Summary__c, run.Package__r.Ownership_Summary__c, 'Ownership summary unchanged');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_COMPLETED, run.Status__c, 'Run completed');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RESULT_PASSED, run.Overall_Result__c, 'Run passed');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_PASSED, run.Package__r.Status__c, 'Package as the full run');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, run.TransmittalProcessingStatus__c, 'Kept summaries count as drafted');
            Assert.isTrue(run.ChangeSummary__c.contains('AI Summary: kept from ' + baseline.Name + ' (nothing changed); owner not emailed'), run.ChangeSummary__c);
            Assert.isTrue(run.ChangeSummary__c.contains('Transmittal Drafting: kept from ' + baseline.Name), run.ChangeSummary__c);
            List<AIReviewStageResult__c> summaries = [
                SELECT ReusedFromResult__c, SummaryType__c FROM AIReviewStageResult__c
                WHERE ReviewRun__c = :runId AND Stage__c = :DNAMSPipelineConstants.STAGE_TRANSMITTAL
            ];
            Assert.areEqual(2, summaries.size(), 'One copied row per summary');
            for (AIReviewStageResult__c row : summaries) {
                Assert.isNotNull(row.ReusedFromResult__c, 'Summary row points at its origin');
            }
        }
    }

    @IsTest
    static void changedRecordValueRechecksAiRuleAndRedraftsSummaries() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpBaseline();
            useRules();
            Stubs stubs = new Stubs();
            runReview(fixture.runId);
            Id accountId = [SELECT Buying_Dealer__c FROM DNAMS_Package__c WHERE Id = :fixture.packageId].Buying_Dealer__c;
            update new Account(Id = accountId, Name = 'DNAMS Test Dealer LLC');

            Id runId = newRun(fixture, DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY);
            new DNAMSRuleValidationStarterQueueable(runId).execute(null);
            Map<String, AIReviewStageResult__c> rows = rowsByRuleId(runId);
            Assert.areEqual(DNAMSPipelineConstants.ROW_PENDING, rows.get('A1').ProcessingStatus__c, 'Changed value: re-checked');
            Assert.isNull(rows.get('A1').ReusedFromResult__c, 'Not reused');
            Assert.isTrue(reloadRun(runId).ChangeSummary__c.contains('Rule Validation: 0 reused, 1 re-checked (A1: values changed), 2 exact/PIR evaluated'),
                reloadRun(runId).ChangeSummary__c);

            new DNAMSAIRuleValidationQueueable(runId).execute(null);
            new DNAMS_PackageNarrativeQueueable(runId, 'test', null).execute(null);
            new DNAMSTransmittalStarterQueueable(runId).execute(null);

            AI_Package_Review_Run__c run = reloadRun(runId);
            Assert.areEqual(2, stubs.validator.calls, 'A1 judged again');
            Assert.areEqual(2, stubs.writer.calls, 'Narrative written again');
            Assert.areEqual(4, stubs.transmittal.calls, 'Summaries drafted again');
            Assert.isTrue(run.Package__r.AI_Narrative_JSON__c.contains(NARRATIVE_JSON_MARKER + ' 2'), 'New narrative stored');
            Assert.isTrue(run.ChangeSummary__c.contains('AI Summary: written again'), run.ChangeSummary__c);
            Assert.isTrue(run.ChangeSummary__c.contains('Transmittal Drafting: drafted again'), run.ChangeSummary__c);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_PASSED, run.Package__r.Status__c, 'Still passes');
        }
    }

    @IsTest
    static void exactMatchIsAlwaysEvaluatedAndAChangedVerdictRedraftsNarrative() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpBaseline();
            useRules();
            Stubs stubs = new Stubs();
            runReview(fixture.runId);
            Id accountId = [SELECT Buying_Dealer__c FROM DNAMS_Package__c WHERE Id = :fixture.packageId].Buying_Dealer__c;
            update new Account(Id = accountId, AccountNumber = 'OTHER01');

            Id runId = newRun(fixture, DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY);
            runReview(runId);

            Map<String, AIReviewStageResult__c> rows = rowsByRuleId(runId);
            AI_Package_Review_Run__c run = reloadRun(runId);
            Assert.areEqual(1, stubs.validator.calls, 'A1 still reused');
            Assert.isNotNull(rows.get('A1').ReusedFromResult__c, 'A1 reused');
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_FAIL, rows.get('V1').Verdict__c, 'ExactMatch evaluated with the new value');
            Assert.areEqual(DNAMSPipelineConstants.HEALTH_RED, run.Package__r.Health__c, 'One of three passing rules failed');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_FAILED, run.Package__r.Status__c, 'Review Failed as a full run');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RESULT_NEEDS_REVIEW, run.Overall_Result__c, 'Needs Review');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.STAGE_FAILED, ruleStatus(fixture), 'Element failed');
            Assert.areEqual(2, stubs.writer.calls, 'A verdict changed: narrative written again');
            Assert.areEqual(2, stubs.transmittal.calls, 'Not GREEN: no transmittal drafting');
        }
    }

    @IsTest
    static void failedRunKeepsNarrativeAndEmailsOnlyWhenTheResultChanged() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpBaseline();
            useRules();
            Id accountId = [SELECT Buying_Dealer__c FROM DNAMS_Package__c WHERE Id = :fixture.packageId].Buying_Dealer__c;
            update new Account(Id = accountId, AccountNumber = 'OTHER01');
            Stubs stubs = new Stubs();
            runReview(fixture.runId);
            AI_Package_Review_Run__c baseline = reloadRun(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.HEALTH_RED, baseline.Package__r.Health__c, 'Baseline RED');

            Id runId = newRun(fixture, DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY);
            runReview(runId);
            AI_Package_Review_Run__c run = reloadRun(runId);
            Assert.areEqual(1, stubs.writer.calls, 'Narrative kept');
            Assert.areEqual(baseline.Package__r.AI_Narrative_JSON__c, run.Package__r.AI_Narrative_JSON__c, 'Narrative unchanged');
            Assert.areEqual(baseline.Package__r.Health__c, run.Package__r.Health__c, 'Health as the full run');
            Assert.areEqual(baseline.Package__r.Status__c, run.Package__r.Status__c, 'Status as the full run');
            Assert.isTrue(run.ChangeSummary__c.contains('owner not emailed (result unchanged)'), run.ChangeSummary__c);

            // The second run's baseline did not finish: same verdicts, but the result is new, so the owner is told
            update new AI_Package_Review_Run__c(Id = runId, Status__c = 'Cancelled');
            Id thirdRunId = newRun(fixture, DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY);
            update new AI_Package_Review_Run__c(Id = thirdRunId, BaselineRun__c = runId);
            runReview(thirdRunId);
            AI_Package_Review_Run__c third = reloadRun(thirdRunId);
            Assert.areEqual(1, stubs.writer.calls, 'Narrative still kept');
            Assert.isTrue(third.ChangeSummary__c.contains('AI Summary: kept from ' + run.Name + ' (nothing changed)'), third.ChangeSummary__c);
            Assert.isFalse(third.ChangeSummary__c.contains('owner not emailed'), third.ChangeSummary__c);
        }
    }

    @IsTest
    static void allModeRunsEverythingAsToday() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpBaseline();
            useRules();
            Stubs stubs = new Stubs();
            runReview(fixture.runId);

            Id runId = newRun(fixture, DNAMSPipelineConstants.RERUN_MODE_ALL);
            new DNAMSRuleValidationStarterQueueable(runId).execute(null);
            Map<String, AIReviewStageResult__c> rows = rowsByRuleId(runId);
            Assert.areEqual(DNAMSPipelineConstants.ROW_PENDING, rows.get('A1').ProcessingStatus__c, 'All mode: AIMatch judged again');
            new DNAMSAIRuleValidationQueueable(runId).execute(null);
            Assert.isNull(reloadRun(runId).Package__r.AI_Narrative_JSON__c, 'All mode GREEN clears the narrative before rewriting it');
            new DNAMS_PackageNarrativeQueueable(runId, 'test', null).execute(null);
            new DNAMSTransmittalStarterQueueable(runId).execute(null);

            AI_Package_Review_Run__c run = reloadRun(runId);
            Assert.areEqual(2, stubs.validator.calls, 'Model called again');
            Assert.areEqual(2, stubs.writer.calls, 'Narrative written again');
            Assert.areEqual(4, stubs.transmittal.calls, 'Summaries drafted again');
            Assert.isNull(run.ChangeSummary__c, 'All runs add no change lines');
            for (AIReviewStageResult__c row : rows.values()) {
                Assert.isNull(row.ReusedFromResult__c, 'Nothing reused in All mode');
            }
        }
    }
}
