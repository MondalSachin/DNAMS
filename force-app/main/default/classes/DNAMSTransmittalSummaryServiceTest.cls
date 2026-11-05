/**
 * @description     Tests for DNAMSTransmittalSummaryService and DNAMSTransmittalStarterQueueable (transmittal drafting).
 *                  The model is a stub (DNAMSTransmittalSummaryService.ai); no prompt template is called.
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
private class DNAMSTransmittalSummaryServiceTest {
    private static final String SSN = '000-48-2917';
    private static final String EIN = '00-4471823';
    private static final String DOB = '08-23-1972';
    private static final String ANSWER = '```json\n{"lines": ["Owned 60% by <Marcus> Whitfield.", "Ridgeline Auto Group holds 40%."]}\n```';
    private static final String ANSWER_HTML = 'Owned 60% by &lt;Marcus&gt; Whitfield.<br>Ridgeline Auto Group holds 40%.';

    /**
     * @description Model stub: answers in order (a String or an Exception to throw); the last answer repeats.
     **/
    private class StubAI implements DNAMSTransmittalAI {
        List<Object> answers = new List<Object>();
        List<String> templates = new List<String>();
        List<String> contexts = new List<String>();

        /**
         * @description Records the call and returns or throws the next answer.
         * @param promptTemplate Prompt template API name
         * @param contextJson    Context JSON
         * @return               The scripted answer
         **/
        public String generate(String promptTemplate, String contextJson) {
            templates.add(promptTemplate);
            contexts.add(contextJson);
            Object answer = answers[Math.min(contexts.size(), answers.size()) - 1];
            if (answer instanceof Exception) {
                throw (Exception) answer;
            }
            return (String) answer;
        }
    }

    /**
     * @description Finalizer context of a job that ended with an unhandled exception.
     **/
    private class CrashedJobContext implements FinalizerContext {
        /**
         * @description Job id (unused).
         * @return      null
         **/
        public Id getAsyncApexJobId() {
            return null;
        }
        /**
         * @description The crash.
         * @return      A DmlException
         **/
        public Exception getException() {
            return new DmlException('boom');
        }
        /**
         * @description Request id (unused).
         * @return      null
         **/
        public String getRequestId() {
            return null;
        }
        /**
         * @description Job result.
         * @return      UNHANDLED_EXCEPTION
         **/
        public ParentJobResult getResult() {
            return ParentJobResult.UNHANDLED_EXCEPTION;
        }
    }

    // ------------------------------------------------------------------ fixture helpers

    /**
     * @description A GREEN run ready for drafting, with the given extraction JSON and test settings.
     * @param consolidated ConsolidatedExtractionJSON__c (null = nothing extracted)
     * @return             The fixture
     **/
    private static DNAMSPipelineTestHelper.PipelineFixture setUpRun(String consolidated) {
        DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
        DNAMS_Pipeline_Setting__mdt settings = DNAMSPipelineTestHelper.getPipelineSettings();
        settings.OwnershipSummaryPromptTemplate__c = 'DNAMS_OwnershipSummary_Prompt';
        settings.ExecutiveSummaryPromptTemplate__c = 'DNAMS_ExecutiveSummary_Prompt';
        settings.TransmittalMaxAttempts__c = 3;
        settings.TransmittalSummaryMaxWords__c = 50;
        settings.PIRRequiredPackageTypes__c = 'Buy/Sell change of Ownership';
        DNAMS_PackageReviewPipelineService.settingsOverride = settings;
        update new AI_Package_Review_Run__c(
            Id = fixture.runId,
            ExtractionProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_COMPLETED,
            RuleValidationProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_COMPLETED,
            RuleValidationPassRate__c = 100,
            TransmittalProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_PENDING,
            ConsolidatedExtractionJSON__c = consolidated
        );
        return fixture;
    }

    /**
     * @description Extraction JSON with owners, key management, an org chart and the sensitive fields.
     * @return      The consolidated JSON
     **/
    private static String extraction() {
        Map<String, Object> dealerApplication = new Map<String, Object>{
            'LegalNameOrDealerEntity' => 'Ridgeline Northstar of Columbus, LLC',
            'TradeName' => 'Ridgeline Northstar',
            'DealershipCity' => 'Columbus',
            'SocialSecurityNumber' => SSN,
            'FederalEIN' => EIN,
            'DateOfBirth' => DOB,
            'OwnershipInfoDirectOwners' => new List<Object>{
                new Map<String, Object>{ 'NameOfOwner' => 'Marcus Whitfield', 'SSNorEIN' => SSN, 'DateOfBirth' => DOB, 'OwnershipPercentage' => '60.00', 'VotingPercentage' => '60.00' }
            },
            'OwnershipInfoIndirectOwners' => new List<Object>{
                new Map<String, Object>{ 'Name' => 'Gregory Hollis', 'SSN' => SSN, 'HeldThrough' => 'Ridgeline Auto Group', 'EffectivePercentageOfDealer' => '12.00' }
            },
            'DealerOperatorAndKeyManagement' => new List<Object>{
                new Map<String, Object>{ 'Name' => 'Danielle Okafor', 'Title' => 'General Manager', 'Email' => 'd@example.com' }
            }
        };
        Map<String, Object> orgChart = new Map<String, Object>{
            'OwnershipStructure' => '[{"OwnerName": "Marcus Whitfield", "OwnerType": "Individual", "OwnedEntityName": "Ridgeline", "OwnershipPercent": "60"}]'
        };
        return JSON.serialize(new Map<String, Object>{
            'DealerApplication' => new List<Object>{ new Map<String, Object>{ 'data' => dealerApplication } },
            'OrgChart' => new List<Object>{ new Map<String, Object>{ 'data' => orgChart } },
            'PhotographsOfFacility' => new List<Object>{ new Map<String, Object>{ 'data' => new Map<String, Object>{ 'AreasPhotographed' => 'not a list' } } }
        });
    }

    /**
     * @description Installs a model stub.
     * @param answers Scripted answers
     * @return        The stub
     **/
    private static StubAI stub(List<Object> answers) {
        StubAI ai = new StubAI();
        ai.answers = answers;
        DNAMSTransmittalSummaryService.ai = ai;
        return ai;
    }

    /**
     * @description Draft request for the current user.
     * @param runId  The run
     * @param source Draft source
     * @return       The request
     **/
    private static DNAMSTransmittalSummaryService.DraftRequest request(Id runId, String source) {
        DNAMSTransmittalSummaryService.DraftRequest request = new DNAMSTransmittalSummaryService.DraftRequest();
        request.runId = runId;
        request.draftSource = source;
        request.requestedBy = UserInfo.getUserId();
        return request;
    }

    /**
     * @description Transmittal stage rows of the run.
     * @param runId The run
     * @return      Rows by SummaryType__c
     **/
    private static Map<String, AIReviewStageResult__c> rowsBySummaryType(Id runId) {
        Map<String, AIReviewStageResult__c> rows = new Map<String, AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : [
            SELECT SummaryType__c, Outcome__c, Reasoning__c, GeneratedText__c, RawStageResponseJSON__c, RequestedBy__c, ProcessingStatus__c, ProcessingErrorDetails__c
            FROM AIReviewStageResult__c
            WHERE ReviewRun__c = :runId AND Stage__c = :DNAMSPipelineConstants.STAGE_TRANSMITTAL
        ]) {
            rows.put(row.SummaryType__c, row);
        }
        return rows;
    }

    /**
     * @description Reloads the package's transmittal fields.
     * @param packageId The package
     * @return          The package
     **/
    private static DNAMS_Package__c reloadPackage(Id packageId) {
        return [SELECT Ownership_Summary__c, Executive_Summary__c, Transmittal_Drafted_At__c, Transmittal_Draft_Source__c FROM DNAMS_Package__c WHERE Id = :packageId];
    }

    /**
     * @description Reloads the run fields the tests assert on.
     * @param runId The run
     * @return      The run
     **/
    private static AI_Package_Review_Run__c reloadRun(Id runId) {
        return [SELECT Status__c, Overall_Result__c, Reason__c, Ended_At__c, TransmittalProcessingStatus__c FROM AI_Package_Review_Run__c WHERE Id = :runId];
    }

    /**
     * @description Inserts one Rule Validation row per verdict.
     * @param runId    The run
     * @param verdicts Verdicts
     **/
    private static void insertRuleRows(Id runId, List<String> verdicts) {
        List<AIReviewStageResult__c> rows = new List<AIReviewStageResult__c>();
        for (String verdict : verdicts) {
            rows.add(new AIReviewStageResult__c(
                ReviewRun__c = runId,
                Stage__c = DNAMSPipelineConstants.STAGE_RULE_VALIDATION,
                RuleId__c = 'R' + rows.size(),
                RuleName__c = 'Rule ' + rows.size(),
                Verdict__c = verdict,
                SourceValue__c = 'source ' + rows.size(),
                ReferenceValue__c = 'reference ' + rows.size(),
                ProcessingStatus__c = DNAMSPipelineConstants.ROW_COMPLETED
            ));
        }
        insert rows;
    }

    // ------------------------------------------------------------------ service

    @IsTest
    static void draftWritesBothSummariesRowsAndCompletesRun() {
        User admin = DNAMSPipelineTestHelper.getAdminUser();
        System.runAs(admin) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun(extraction());
            StubAI ai = stub(new List<Object>{ ANSWER });

            Test.startTest();
            DNAMSTransmittalSummaryService.DraftResult result = DNAMSTransmittalSummaryService.draft(request(fixture.runId, DNAMSPipelineConstants.DRAFT_SOURCE_RMR_DRAFT));
            Test.stopTest();

            Assert.isTrue(result.success, result.message);
            Assert.areEqual(ANSWER_HTML, result.ownershipHtml, 'Each line escaped, joined with <br>');
            Assert.areEqual(new List<String>{ 'DNAMS_OwnershipSummary_Prompt', 'DNAMS_ExecutiveSummary_Prompt' }, ai.templates, 'Ownership first, then executive');
            for (String context : ai.contexts) {
                Assert.isFalse(context.contains(SSN) || context.contains(EIN) || context.contains(DOB), 'No SSN, EIN or DOB sent: ' + context);
            }
            Map<String, Object> ownership = (Map<String, Object>) JSON.deserializeUntyped(ai.contexts[0]);
            Assert.areEqual(1, ((List<Object>) ownership.get('directOwners')).size(), 'Direct owners sent');
            Assert.areEqual(1, ((List<Object>) ownership.get('ownershipStructure')).size(), 'Org chart JSON string parsed');
            Assert.areEqual(false, ((Map<String, Object>) ownership.get('pir')).get('applicable'), 'PIR not required for Term Renewal');
            Map<String, Object> executive = (Map<String, Object>) JSON.deserializeUntyped(ai.contexts[1]);
            Assert.isTrue(String.valueOf(executive.get('ownershipSummary')).contains('Ridgeline Auto Group holds 40%.'), 'Executive gets the ownership lines');
            Assert.areEqual(0, ((List<Object>) ((Map<String, Object>) executive.get('facts')).get('facilityAreasPhotographed')).size(), 'Unreadable list tolerated');

            DNAMS_Package__c pkg = reloadPackage(fixture.packageId);
            Assert.areEqual(ANSWER_HTML, pkg.Ownership_Summary__c, 'Ownership summary written');
            Assert.areEqual(ANSWER_HTML, pkg.Executive_Summary__c, 'Executive summary written');
            Assert.areEqual(DNAMSPipelineConstants.DRAFT_SOURCE_RMR_DRAFT, pkg.Transmittal_Draft_Source__c, 'Draft source');
            Assert.isNotNull(pkg.Transmittal_Drafted_At__c, 'Drafted at');

            Map<String, AIReviewStageResult__c> rows = rowsBySummaryType(fixture.runId);
            Assert.areEqual(2, rows.size(), 'One row per summary');
            for (String summaryType : new List<String>{ DNAMSPipelineConstants.SUMMARY_OWNERSHIP, DNAMSPipelineConstants.SUMMARY_EXECUTIVE }) {
                AIReviewStageResult__c row = rows.get(summaryType);
                Assert.areEqual(DNAMSPipelineConstants.ROW_COMPLETED, row.ProcessingStatus__c, summaryType);
                Assert.areEqual(DNAMSPipelineConstants.DRAFT_SOURCE_RMR_DRAFT, row.Outcome__c, summaryType + ' outcome');
                Assert.areEqual(ANSWER_HTML, row.GeneratedText__c, summaryType + ' text');
                Assert.areEqual(ANSWER, row.RawStageResponseJSON__c, summaryType + ' raw');
                Assert.areEqual(admin.Id, row.RequestedBy__c, summaryType + ' requested by');
                Assert.isTrue(row.Reasoning__c.startsWith('Drafted by RMR DNAMS Test Admin.'), row.Reasoning__c);
            }
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, reloadRun(fixture.runId).TransmittalProcessingStatus__c, 'Run transmittal completed');
        }
    }

    @IsTest
    static void rateLimitAndUnreadableAnswersAreRetried() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun(extraction());
            StubAI ai = stub(new List<Object>{ new DNAMSPipelineException('HTTP 429: Too Many Requests'), 'Sorry, I cannot help.', ANSWER });

            DNAMSTransmittalSummaryService.DraftResult result = DNAMSTransmittalSummaryService.draft(request(fixture.runId, DNAMSPipelineConstants.DRAFT_SOURCE_AUTO));

            Assert.isTrue(result.success, result.message);
            Assert.areEqual(4, ai.contexts.size(), 'Three ownership attempts, one executive');
            Map<String, AIReviewStageResult__c> rows = rowsBySummaryType(fixture.runId);
            Assert.isTrue(rows.get(DNAMSPipelineConstants.SUMMARY_OWNERSHIP).Reasoning__c.contains('Attempts: 3.'), 'Attempts recorded');
            Assert.isTrue(rows.get(DNAMSPipelineConstants.SUMMARY_EXECUTIVE).Reasoning__c.startsWith('Drafted automatically'), 'Auto note');
        }
    }

    @IsTest
    static void nonRetryableErrorFailsWithoutTouchingThePackage() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun(extraction());
            StubAI ai = stub(new List<Object>{ new DNAMSPipelineException('Prompt template not found') });

            DNAMSTransmittalSummaryService.DraftResult result = DNAMSTransmittalSummaryService.draft(request(fixture.runId, DNAMSPipelineConstants.DRAFT_SOURCE_RMR_DRAFT));

            Assert.isFalse(result.success, 'Draft failed');
            Assert.isFalse(result.message.contains('Prompt template'), 'User-safe message');
            Assert.areEqual(1, ai.contexts.size(), 'No retry for a non-retryable error');
            DNAMS_Package__c pkg = reloadPackage(fixture.packageId);
            Assert.isNull(pkg.Ownership_Summary__c, 'Package unchanged');
            Assert.isNull(pkg.Transmittal_Draft_Source__c, 'Package unchanged');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_FAILED, reloadRun(fixture.runId).TransmittalProcessingStatus__c, 'Run transmittal failed');
            AIReviewStageResult__c row = rowsBySummaryType(fixture.runId).get(DNAMSPipelineConstants.SUMMARY_OWNERSHIP);
            Assert.areEqual(DNAMSPipelineConstants.ROW_ERROR, row.ProcessingStatus__c, 'Error row');
            Assert.isTrue(row.ProcessingErrorDetails__c.contains('Prompt template not found'), row.ProcessingErrorDetails__c);
            List<AIReviewErrorLog__c> logs = [SELECT Stage__c, ErrorType__c, StageResult__c FROM AIReviewErrorLog__c WHERE ReviewRun__c = :fixture.runId];
            Assert.areEqual(1, logs.size(), 'One error log');
            Assert.areEqual(DNAMSPipelineConstants.STAGE_TRANSMITTAL, logs[0].Stage__c, 'Log stage');
            Assert.areEqual(DNAMSPipelineConstants.ERROR_PROCESSING, logs[0].ErrorType__c, 'Log type');
            Assert.areEqual(row.Id, logs[0].StageResult__c, 'Log linked to the error row');
        }
    }

    @IsTest
    static void overLongAnswerIsKeptInFull() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun(extraction());
            DNAMS_Pipeline_Setting__mdt settings = DNAMS_PackageReviewPipelineService.settings();
            settings.TransmittalMaxAttempts__c = 2;
            settings.TransmittalSummaryMaxWords__c = 5;
            StubAI ai = stub(new List<Object>{ '{"lines": ["One two three.", "Four five six seven.", "Eight."]}' });

            DNAMSTransmittalSummaryService.DraftResult result = DNAMSTransmittalSummaryService.draft(request(fixture.runId, DNAMSPipelineConstants.DRAFT_SOURCE_AUTO));

            Assert.isTrue(result.success, result.message);
            Assert.areEqual(2, ai.contexts.size(), 'One attempt per summary: length never triggers a retry');
            Assert.areEqual('One two three.<br>Four five six seven.<br>Eight.', result.ownershipHtml, 'Nothing trimmed');
            Assert.isTrue(rowsBySummaryType(fixture.runId).get(DNAMSPipelineConstants.SUMMARY_OWNERSHIP).Reasoning__c.contains('8 words (asked for 5); kept in full'), 'Length noted');
        }
    }

    @IsTest
    static void overrideNoteCountsFailingRules() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun(extraction());
            insertRuleRows(fixture.runId, new List<String>{
                DNAMSPipelineConstants.VERDICT_PASS,
                DNAMSPipelineConstants.VERDICT_FAIL,
                DNAMSPipelineConstants.VERDICT_CANNOT_DECIDE,
                DNAMSPipelineConstants.VERDICT_NOT_APPLICABLE
            });
            StubAI ai = stub(new List<Object>{ ANSWER });

            Assert.areEqual(2, DNAMSTransmittalSummaryService.failingRuleCount(fixture.runId), 'FAIL and CANNOT_DECIDE');
            DNAMSTransmittalSummaryService.DraftResult result = DNAMSTransmittalSummaryService.draft(request(fixture.runId, DNAMSPipelineConstants.DRAFT_SOURCE_RMR_OVERRIDE));

            Assert.isTrue(result.success, result.message);
            AIReviewStageResult__c row = rowsBySummaryType(fixture.runId).get(DNAMSPipelineConstants.SUMMARY_EXECUTIVE);
            Assert.isTrue(row.Reasoning__c.contains('despite 2 failing rule(s)'), row.Reasoning__c);
            Map<String, Object> ruleValidation = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(ai.contexts[1])).get('ruleValidation');
            Assert.areEqual(3, ruleValidation.get('applicable'), 'NOT_APPLICABLE left out');
            Assert.areEqual(1, ruleValidation.get('passed'), 'Passed count');
            Assert.areEqual(2, ((List<Object>) ruleValidation.get('failedRules')).size(), 'Failed rules sent');
        }
    }

    @IsTest
    static void missingExtractionIsTolerated() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun(null);
            StubAI ai = stub(new List<Object>{ ANSWER });

            DNAMSTransmittalSummaryService.DraftResult result = DNAMSTransmittalSummaryService.draft(request(fixture.runId, DNAMSPipelineConstants.DRAFT_SOURCE_RMR_REDRAFT));

            Assert.isTrue(result.success, result.message);
            Map<String, Object> ownership = (Map<String, Object>) JSON.deserializeUntyped(ai.contexts[0]);
            Assert.areEqual('DNAMS Test Dealer', ((Map<String, Object>) ownership.get('dealer')).get('legalName'), 'Falls back to the buying dealer');
            Assert.isTrue(((List<Object>) ownership.get('directOwners')).isEmpty(), 'No owners');
            Assert.isTrue(rowsBySummaryType(fixture.runId).get(DNAMSPipelineConstants.SUMMARY_OWNERSHIP).Reasoning__c.startsWith('Regenerated by RMR'), 'Redraft note');
        }
    }

    @IsTest
    static void helpersReadAndTrimLines() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Assert.isNull(DNAMSTransmittalSummaryService.parseLines('{"lines": []}'), 'Empty lines');
            Assert.isNull(DNAMSTransmittalSummaryService.parseLines('{"lines": "text"}'), 'Not a list');
            Assert.isNull(DNAMSTransmittalSummaryService.parseLines(null), 'No answer');
            Assert.areEqual(new List<String>{ 'a b' }, DNAMSTransmittalSummaryService.parseLines('x {"lines": [" a b ", ""]} y'), 'Text around ignored');
            Assert.areEqual(3, DNAMSTransmittalSummaryService.words(new List<String>{ 'a  b', 'c' }), 'Words across lines');
            Assert.isTrue(DNAMSTransmittalSummaryService.isRetryable('Rate Limit exceeded'), 'Rate limit');
            Assert.isFalse(DNAMSTransmittalSummaryService.isRetryable(null), 'No message');
        }
    }

    // ------------------------------------------------------------------ queueable (auto path)

    @IsTest
    static void autoDraftCompletesRunAsPassed() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun(extraction());
            stub(new List<Object>{ ANSWER });

            new DNAMSTransmittalStarterQueueable(fixture.runId).execute(null);

            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_COMPLETED, run.Status__c, 'Run completed');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RESULT_PASSED, run.Overall_Result__c, 'Run passed');
            Assert.isNotNull(run.Ended_At__c, 'Ended at');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, run.TransmittalProcessingStatus__c, 'Drafted');
            Assert.isTrue(run.Reason__c.contains(DNAMSTransmittalStarterQueueable.DRAFTED_REASON), run.Reason__c);
            Assert.areEqual(DNAMSPipelineConstants.DRAFT_SOURCE_AUTO, reloadPackage(fixture.packageId).Transmittal_Draft_Source__c, 'Source Auto');
        }
    }

    @IsTest
    static void autoDraftFailureStillPassesRun() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun(extraction());
            stub(new List<Object>{ new DNAMSPipelineException('model unavailable') });

            new DNAMSTransmittalStarterQueueable(fixture.runId).execute(null);

            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RESULT_PASSED, run.Overall_Result__c, 'Rules passed, so the run passes');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_FAILED, run.TransmittalProcessingStatus__c, 'Transmittal failed');
            Assert.isTrue(run.Reason__c.contains(DNAMSTransmittalStarterQueueable.DRAFT_FAILED_REASON), run.Reason__c);
        }
    }

    @IsTest
    static void crashFinalizerPassesRunAndFailsTransmittal() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun(extraction());

            new DNAMSTransmittalStarterQueueable.CrashFinalizer(fixture.runId).execute(new CrashedJobContext());

            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_COMPLETED, run.Status__c, 'Run completed');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_FAILED, run.TransmittalProcessingStatus__c, 'Transmittal failed');
            Assert.areEqual(1, [SELECT COUNT() FROM AIReviewErrorLog__c WHERE ReviewRun__c = :fixture.runId AND Stage__c = :DNAMSPipelineConstants.STAGE_TRANSMITTAL], 'Crash logged');
        }
    }
}
