/**
 * @description     Tests for the rule validation stage: DNAMSRuleValidationStarterQueueable, DNAMSRuleEvaluator,
 *                  DNAMSAIRuleValidationQueueable, DNAMSRuleValidationCompletionHelper, DNAMSTransmittalStarterQueueable
 *                  and DNAMSRuleUtil. Rules are injected in memory (DNAMSRuleUtil.rulesOverride) and the model is stubbed.
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-05
 * @last modified by Abhishek Dutta
 * @last modification details Transmittal drafting replaces the placeholder
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-04   Sachin Mondal   Initial version
 * 1.1   2026-11-05   Abhishek Dutta  StageFailureFinalizer test
 * 1.2   2026-11-05   Abhishek Dutta  Transmittal drafting replaces the placeholder
 **/
@IsTest
private class DNAMSRuleValidationTest {
    private static final String DEALER_CODE = 'TCE00087';
    private static final String DEALER_NAME = 'DNAMS Test Dealer';
    private static final String DA = 'Dealer Application';

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

    private class StubValidator implements DNAMSRuleAIValidator {
        String answer;
        Boolean fail = false;
        Integer calls = 0;
        public String validate(String promptTemplate, String comparisonsJson) {
            calls++;
            if (fail) {
                throw new DNAMSPipelineException('model unavailable');
            }
            return answer;
        }
    }

    // ------------------------------------------------------------------ fixture helpers

    private static DNAMSPipelineTestHelper.PipelineFixture setUpRun() {
        DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
        DNAMS_Pipeline_Setting__mdt settings = DNAMSPipelineTestHelper.getPipelineSettings();
        settings.RuleValidationBatchSize__c = 50;
        settings.RuleValidationPromptTemplate__c = 'DNAMS_RuleValidation_Prompt';
        settings.PIRRequiredPackageTypes__c = 'Buy/Sell change of Ownership;Dealer Principal Change';
        settings.Max_Attempts__c = 2;
        DNAMS_PackageReviewPipelineService.settingsOverride = settings;
        Map<String, Object> dealerApplication = new Map<String, Object>{
            'DealerCode' => DEALER_CODE,
            'LegalNameOrDealerEntity' => 'dnams  TEST dealer',
            'DealerOperatorSigningDate' => Date.today().addDays(-10).month() + '-' + Date.today().addDays(-10).day() + '-' + Date.today().addDays(-10).year(),
            'isSignatureOfDealerOperatorPresent' => 'True',
            'FederalEIN' => ''
        };
        Map<String, Object> photographs = new Map<String, Object>{ 'AreasPhotographed' => '["Exterior", "Showroom"]' };
        String consolidated = JSON.serialize(new Map<String, Object>{
            'DealerApplication' => new List<Object>{ new Map<String, Object>{ 'elementType' => DA, 'data' => dealerApplication } },
            'PhotographsOfFacility' => new List<Object>{ new Map<String, Object>{ 'elementType' => 'Photographs of Facility', 'data' => photographs } }
        });
        update new AI_Package_Review_Run__c(
            Id = fixture.runId,
            ExtractionProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_COMPLETED,
            ConsolidatedExtractionJSON__c = consolidated
        );
        return fixture;
    }

    private static DNAMSRule__mdt rule(String id, String method, String sourceType, String sourceKey, String comparator, String referenceType, String referenceKey) {
        return new DNAMSRule__mdt(
            DeveloperName = id,
            MasterLabel = 'Rule ' + id,
            Description__c = 'Test rule ' + id,
            RuleType__c = 'Validation',
            ValidationMethod__c = method,
            RuleAppliedTo__c = 'Element',
            RelativeElementType__c = DA,
            SourceFieldType__c = sourceType,
            SourceFieldKey__c = sourceKey,
            Comparator__c = comparator,
            ReferenceFieldType__c = referenceType,
            ReferenceFieldKey__c = referenceKey,
            IsActive__c = true
        );
    }

    private static DNAMSRule__mdt passingRule(String id) {
        return rule(id, 'ExactMatch', 'Extraction', 'extraction.DealerApplication.DealerCode', 'EQUALS', 'Record', 'Package.Buying_Dealer__r.AccountNumber');
    }

    private static DNAMSRule__mdt failingRule(String id) {
        return rule(id, 'ExactMatch', 'Extraction', 'extraction.DealerApplication.DealerCode', 'EQUALS', 'Static', 'OTHER-CODE');
    }

    private static AI_Package_Review_Run__c reloadRun(Id runId) {
        return [
            SELECT Status__c, Overall_Result__c, Issue_Summary__c, Reason__c, RuleValidationProcessingStatus__c, RuleValidationPassRate__c,
                ExactMatchPassRate__c, AIMatchPassRate__c, Package__r.Health__c, Package__r.Status__c, TransmittalProcessingStatus__c
            FROM AI_Package_Review_Run__c
            WHERE Id = :runId
        ];
    }

    private static Map<String, AIReviewStageResult__c> rowsByRuleId(Id runId) {
        Map<String, AIReviewStageResult__c> rows = new Map<String, AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : [
            SELECT RuleId__c, Verdict__c, Reasoning__c, ProcessingStatus__c, SourceValue__c, ReferenceValue__c, PackageElement__c, ComparisonMethod__c
            FROM AIReviewStageResult__c
            WHERE ReviewRun__c = :runId AND Stage__c = :DNAMSPipelineConstants.STAGE_RULE_VALIDATION
        ]) {
            rows.put(row.RuleId__c, row);
        }
        return rows;
    }

    private static DNAMS_Package_Element__c element(DNAMSPipelineTestHelper.PipelineFixture fixture, String name) {
        return [SELECT Rule_Validation_Status__c, Element_Narrative__c, Current_Stage__c FROM DNAMS_Package_Element__c WHERE Id = :fixture.elementIdByType.get(name)];
    }

    // ------------------------------------------------------------------ end to end

    @IsTest
    static void allRulesPassIsGreenAndMovesToTransmittal() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun();
            DNAMSRule__mdt completeness = rule('C1', 'ExactMatch', 'Extraction',
                '["extraction.DealerApplication.DealerCode","extraction.DealerApplication.LegalNameOrDealerEntity"]', 'NOT EQUALS', 'Static', '');
            completeness.RuleType__c = 'Completeness';
            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>{
                completeness,
                passingRule('V1'),
                rule('V2', 'ExactMatch', 'Extraction', 'extraction.DealerApplication.LegalNameOrDealerEntity', 'EQUALS', 'Record', 'Package.Buying_Dealer__r.Name'),
                rule('V3', 'ExactMatch', 'Extraction', 'extraction.DealerApplication.isSignatureOfDealerOperatorPresent', 'EQUALS', 'Static', 'true'),
                rule('V4', 'ExactMatch', 'Extraction', 'extraction.DealerApplication.DealerOperatorSigningDate', 'GE', 'Static', '{TODAY-90}'),
                rule('V5', 'ExactMatch', 'Static', 'Exterior', 'IN', 'Extraction', 'extraction.PhotographsOfFacility.AreasPhotographed')
            };

            new DNAMSRuleValidationStarterQueueable(fixture.runId).execute(null);

            Map<String, AIReviewStageResult__c> rows = rowsByRuleId(fixture.runId);
            Assert.areEqual(7, rows.size(), 'One row per rule plus the PIR row');
            for (String ruleId : new List<String>{ 'C1', 'V1', 'V2', 'V3', 'V4', 'V5' }) {
                Assert.areEqual(DNAMSPipelineConstants.VERDICT_PASS, rows.get(ruleId).Verdict__c, ruleId + ': ' + rows.get(ruleId).Reasoning__c);
            }
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_NOT_APPLICABLE, rows.get('PIR').Verdict__c, 'PIR is not required for Term Renewal');
            Assert.areEqual(DEALER_CODE, rows.get('V1').ReferenceValue__c, 'Reference value stored');
            Assert.areEqual(fixture.elementIdByType.get(DA), rows.get('V1').PackageElement__c, 'Row linked to its element');

            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, run.RuleValidationProcessingStatus__c, 'Stage completed');
            Assert.areEqual(100, run.RuleValidationPassRate__c.intValue(), 'Pass rate');
            Assert.areEqual(100, run.ExactMatchPassRate__c.intValue(), 'ExactMatch pass rate');
            Assert.isNull(run.AIMatchPassRate__c, 'No AIMatch rule');
            Assert.areEqual(DNAMSPipelineConstants.HEALTH_GREEN, run.Package__r.Health__c, 'Package Green');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.PACKAGE_UNDER_REVIEW, run.Package__r.Status__c, 'Package stays Under Review while drafting');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_RUNNING, run.Status__c, 'Run waits for transmittal drafting');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_PENDING, run.TransmittalProcessingStatus__c, 'Transmittal drafting pending');
            DNAMS_Package_Element__c dealerApplication = element(fixture, DA);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.STAGE_PASSED, dealerApplication.Rule_Validation_Status__c, 'Element passed');
            Assert.areEqual(DNAMSPipelineConstants.STAGE_RULE_VALIDATION, dealerApplication.Current_Stage__c, 'Element stage');

            new DNAMSTransmittalStarterQueueable(fixture.runId).execute(null);
            run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_COMPLETED, run.Status__c, 'Run completed');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RESULT_PASSED, run.Overall_Result__c, 'Run passed');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_PASSED, run.Package__r.Status__c, 'A passed run passes the review');
            // No prompt is stubbed here, so drafting may succeed or fail; either way the GREEN run passes
            Assert.isTrue(run.Reason__c.contains('Rule validation passed (GREEN).'), run.Reason__c);
            Assert.areNotEqual(DNAMSPipelineConstants.RUN_STAGE_PENDING, run.TransmittalProcessingStatus__c, 'Transmittal drafting settled');
        }
    }

    @IsTest
    static void failedRulesAreRedAndNeedReview() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun();
            DNAMSRule__mdt completeness = rule('C1', 'ExactMatch', 'Extraction',
                '["extraction.DealerApplication.DealerCode","extraction.DealerApplication.FederalEIN"]', 'NOT EQUALS', 'Static', '\'\'');
            completeness.RuleType__c = 'Completeness';
            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>{ completeness, failingRule('V1'), passingRule('V2') };

            new DNAMSRuleValidationStarterQueueable(fixture.runId).execute(null);

            Map<String, AIReviewStageResult__c> rows = rowsByRuleId(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_FAIL, rows.get('C1').Verdict__c, 'Blank field fails completeness');
            Assert.isTrue(rows.get('C1').Reasoning__c.contains('Federal EIN'), rows.get('C1').Reasoning__c);
            Assert.isTrue(rows.get('V1').Reasoning__c.contains('does not match'), rows.get('V1').Reasoning__c);
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_FAIL, rows.get('V1').Verdict__c, 'Different value fails');

            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(33.33, run.RuleValidationPassRate__c.setScale(2), 'One of three applicable rules passed');
            Assert.areEqual(DNAMSPipelineConstants.HEALTH_RED, run.Package__r.Health__c, 'Package Red');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_FAILED, run.Package__r.Status__c, 'Red fails the review');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_COMPLETED, run.Status__c, 'Run completed');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RESULT_NEEDS_REVIEW, run.Overall_Result__c, 'Needs review');
            Assert.isTrue(run.Issue_Summary__c.contains('Rule V1'), run.Issue_Summary__c);
            DNAMS_Package_Element__c dealerApplication = element(fixture, DA);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.STAGE_FAILED, dealerApplication.Rule_Validation_Status__c, 'Element failed');
            Assert.isTrue(dealerApplication.Element_Narrative__c.startsWith('Rules not met'), dealerApplication.Element_Narrative__c);
        }
    }

    @IsTest
    static void passRateBetween85And100IsAmber() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun();
            List<DNAMSRule__mdt> rules = new List<DNAMSRule__mdt>{ failingRule('F1') };
            for (Integer i = 1; i <= 6; i++) {
                rules.add(passingRule('P' + i));
            }
            DNAMSRuleUtil.rulesOverride = rules;

            new DNAMSRuleValidationStarterQueueable(fixture.runId).execute(null);

            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(85.71, run.RuleValidationPassRate__c.setScale(2), 'Six of seven');
            Assert.areEqual(DNAMSPipelineConstants.HEALTH_AMBER, run.Package__r.Health__c, 'Package Amber');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_FAILED, run.Package__r.Status__c, 'Amber fails the review');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.STAGE_FAILED, element(fixture, DA).Rule_Validation_Status__c, 'Elements are pass/fail only; the package is Amber');
        }
    }

    @IsTest
    static void missingDocumentsAndEmptyRecordPathsAreNotApplicable() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun();
            DNAMSRule__mdt utilityBill = rule('N1', 'ExactMatch', 'Extraction', 'extraction.UtilityBill.AccountHolderName', 'EQUALS', 'Record', 'Package.Buying_Dealer__r.Name');
            DNAMSRule__mdt parent = rule('N2', 'AIMatch', 'Record', 'Package.Buying_Dealer__r.Parent.Name', 'IN', 'Extraction', 'extraction.DealerApplication.LegalNameOrDealerEntity');
            DNAMSRule__mdt badPath = rule('E1', 'ExactMatch', 'Extraction', 'extraction.DealerApplication.DealerCode', 'EQUALS', 'Record', 'Package.Buying_Dealer__r.No_Such_Field__c');
            DNAMSRule__mdt otherType = passingRule('X1');
            otherType.RelativePackageType__c = 'Buy/Sell change of Ownership';
            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>{ utilityBill, parent, badPath, otherType };

            new DNAMSRuleValidationStarterQueueable(fixture.runId).execute(null);

            Map<String, AIReviewStageResult__c> rows = rowsByRuleId(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_NOT_APPLICABLE, rows.get('N1').Verdict__c, 'No utility bill uploaded');
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_NOT_APPLICABLE, rows.get('N2').Verdict__c, 'Dealer has no parent account');
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_CANNOT_DECIDE, rows.get('E1').Verdict__c, 'Unreadable record path');
            Assert.isFalse(rows.containsKey('X1'), 'Rules of another package type are skipped');
            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(0, run.RuleValidationPassRate__c.intValue(), 'Only the undecidable rule counts');
            Assert.areEqual(DNAMSPipelineConstants.HEALTH_RED, run.Package__r.Health__c, 'CANNOT_DECIDE counts against the pass rate');
        }
    }

    @IsTest
    static void aiMatchRulesAreJudgedByTheModel() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun();
            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>{
                passingRule('V1'),
                rule('A1', 'AIMatch', 'Extraction', 'extraction.DealerApplication.LegalNameOrDealerEntity', 'EQUALS', 'Record', 'Package.Buying_Dealer__r.Name'),
                rule('A2', 'AIMatch', 'Extraction', '["extraction.DealerApplication.DealerCode","extraction.DealerApplication.FederalEIN"]', 'EQUALS', 'Record', 'Package.Buying_Dealer__r.AccountNumber')
            };
            StubValidator stub = new StubValidator();
            stub.answer = '```json\n[{"rule_id":"A1","verdict":"PASS","reasoning":"Same entity."},{"rule_id":"A2","verdict":"maybe","reasoning":"?"}]\n```';
            DNAMSAIRuleValidationQueueable.validator = stub;

            new DNAMSRuleValidationStarterQueueable(fixture.runId).execute(null);
            Assert.areEqual(DNAMSPipelineConstants.ROW_PENDING, rowsByRuleId(fixture.runId).get('A1').ProcessingStatus__c, 'AIMatch waits for the model');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_IN_PROGRESS, reloadRun(fixture.runId).RuleValidationProcessingStatus__c, 'Stage in progress');

            new DNAMSAIRuleValidationQueueable(fixture.runId).execute(null);

            Map<String, AIReviewStageResult__c> rows = rowsByRuleId(fixture.runId);
            Assert.areEqual(1, stub.calls, 'One model call for the batch');
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_PASS, rows.get('A1').Verdict__c, 'Model verdict stored');
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_CANNOT_DECIDE, rows.get('A2').Verdict__c, 'Unusable verdict');
            Assert.isTrue(rows.get('A2').SourceValue__c.contains('DealerCode'), 'Several keys are sent by name: ' + rows.get('A2').SourceValue__c);
            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(50, run.AIMatchPassRate__c.intValue(), 'AIMatch pass rate');
            Assert.areEqual(100, run.ExactMatchPassRate__c.intValue(), 'ExactMatch pass rate');
            Assert.areEqual(DNAMSPipelineConstants.HEALTH_RED, run.Package__r.Health__c, 'Two of three is Red');
        }
    }

    @IsTest
    static void aiMatchFailureAfterRetriesCannotDecide() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun();
            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>{
                rule('A1', 'AIMatch', 'Extraction', 'extraction.DealerApplication.LegalNameOrDealerEntity', 'EQUALS', 'Record', 'Package.Buying_Dealer__r.Name')
            };
            StubValidator stub = new StubValidator();
            stub.fail = true;
            DNAMSAIRuleValidationQueueable.validator = stub;

            new DNAMSRuleValidationStarterQueueable(fixture.runId).execute(null);
            new DNAMSAIRuleValidationQueueable(fixture.runId).execute(null);

            AIReviewStageResult__c row = rowsByRuleId(fixture.runId).get('A1');
            Assert.areEqual(2, stub.calls, 'Retried up to Max Attempts');
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_CANNOT_DECIDE, row.Verdict__c, 'No verdict');
            Assert.isTrue(row.Reasoning__c.contains('model unavailable'), row.Reasoning__c);
        }
    }

    @IsTest
    static void pirFailureMakesPackageRedAndBypassIsRecorded() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun();
            Account seller = new Account(Name = 'Selling Dealer', AccountNumber = 'SELL001');
            insert seller;
            update new DNAMS_Package__c(Id = fixture.packageId, Type__c = 'Buy/Sell change of Ownership', Selling_Dealer__c = seller.Id, PIR_Linked__c = true);
            DNAMSRule__mdt packageRule = rule('K1', 'ExactMatch', 'Extraction', 'extraction.DealerApplication.LegalNameOrDealerEntity', 'NOT EQUALS', 'Record', 'Package.Selling_Dealer__r.Name');
            packageRule.RuleAppliedTo__c = 'Package';
            packageRule.RelativeElementType__c = null;
            packageRule.RelativePackageType__c = 'Buy/Sell change of Ownership';
            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>{ packageRule, passingRule('V1') };

            new DNAMSRuleValidationStarterQueueable(fixture.runId).execute(null);

            Map<String, AIReviewStageResult__c> rows = rowsByRuleId(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_PASS, rows.get('K1').Verdict__c, 'Package-level rule: ' + rows.get('K1').Reasoning__c);
            Assert.isNull(rows.get('K1').PackageElement__c, 'Package-level rows have no element');
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_FAIL, rows.get('PIR').Verdict__c, 'Linked but not cleared');
            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMSPipelineConstants.HEALTH_RED, run.Package__r.Health__c, 'A failed PIR makes the package Red');

            DNAMSRuleValidationStarterQueueable starter = new DNAMSRuleValidationStarterQueueable(fixture.runId);
            DNAMS_Package__c pkg = new DNAMS_Package__c(Type__c = 'Buy/Sell change of Ownership', PIR_Bypass_Acknowledged__c = true, PIR_Bypass_Reason__c = 'Approved exception');
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_NOT_APPLICABLE, starter.pirRow(pkg).Verdict__c, 'Bypass recorded');
            pkg = new DNAMS_Package__c(Type__c = 'Dealer Principal Change');
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_FAIL, starter.pirRow(pkg).Verdict__c, 'Not linked');
            pkg = new DNAMS_Package__c(Type__c = 'Dealer Principal Change', PIR_Linked__c = true, PIR_Cleared__c = true);
            Assert.areEqual(DNAMSPipelineConstants.VERDICT_PASS, starter.pirRow(pkg).Verdict__c, 'Linked and cleared');
        }
    }

    @IsTest
    static void cancelledRunIsLeftAlone() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun();
            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>{ passingRule('V1') };
            DNAMS_PackageReviewPipelineService.cancelActiveRun(fixture.packageId);

            new DNAMSRuleValidationStarterQueueable(fixture.runId).execute(null);
            new DNAMSAIRuleValidationQueueable(fixture.runId).execute(null);
            new DNAMSTransmittalStarterQueueable(fixture.runId).execute(null);

            Assert.isTrue(rowsByRuleId(fixture.runId).isEmpty(), 'No rows for a cancelled run');
            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual(DNAMS_PackageReviewPipelineService.RUN_CANCELLED, run.Status__c, 'Cancelled');
            Assert.isNull(run.RuleValidationProcessingStatus__c, 'Stage never started');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.PACKAGE_RMR_PENDING, run.Package__r.Status__c, 'Cancel leaves the package RMR Pending');
        }
    }

    @IsTest
    static void secondStartOfTheSameRunDoesNothing() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun();
            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>{ passingRule('V1'), failingRule('V2') };

            new DNAMSRuleValidationStarterQueueable(fixture.runId).execute(null);
            new DNAMSRuleValidationStarterQueueable(fixture.runId).execute(null);

            Assert.areEqual(
                3,
                [SELECT COUNT() FROM AIReviewStageResult__c WHERE ReviewRun__c = :fixture.runId AND Stage__c = :DNAMSPipelineConstants.STAGE_RULE_VALIDATION],
                'Rows are created once (2 rules + PIR)'
            );
        }
    }

    // ------------------------------------------------------------------ units

    @IsTest
    static void exactMatchNormalisation() {
        Assert.isTrue(DNAMSRuleEvaluator.areEqual('  ABC  Motors LLC ', 'abc motors llc'), 'Case and spacing');
        Assert.isFalse(DNAMSRuleEvaluator.areEqual('ABC Motors, LLC', 'ABC Motors LLC'), 'Punctuation is kept');
        Assert.isTrue(DNAMSRuleEvaluator.areEqual('100', '100.00'), 'Numbers');
        Assert.isTrue(DNAMSRuleEvaluator.areEqual('1,250', 1250), 'Thousands separator');
        Assert.isTrue(DNAMSRuleEvaluator.areEqual('True', 'yes'), 'Booleans');
        Assert.isTrue(DNAMSRuleEvaluator.areEqual('08-23-1972', '1972-08-23'), 'US and ISO dates');
        Assert.areEqual(Date.today().addDays(-90), DNAMSRuleEvaluator.toDate('{TODAY-90}'), 'Date token');
        Assert.areEqual(Date.today(), DNAMSRuleEvaluator.toDate('{today}'), 'Today token');
        Assert.isNull(DNAMSRuleEvaluator.toDate('13-45-2020'), 'Invalid date');
        Assert.isTrue(DNAMSRuleEvaluator.compare('2026-01-02', '2026-01-01') > 0, 'Date order');
        Assert.isTrue(DNAMSRuleEvaluator.compare('5', '10') < 0, 'Number order');
        Assert.isTrue(DNAMSRuleEvaluator.satisfies('IN', 'Corrected', new List<Object>{ 'Confirmed', 'Corrected' }), 'IN');
        Assert.isTrue(DNAMSRuleEvaluator.satisfies('NOT IN', 'Unchecked', new List<Object>{ 'Confirmed', 'Corrected' }), 'NOT IN');
        Assert.isTrue(DNAMSRuleEvaluator.satisfies('NOT EQUALS', 'x', new List<Object>{ '' }), 'NOT EQUALS');
        Assert.isTrue(DNAMSRuleEvaluator.satisfies('LE', '3', new List<Object>{ '3' }), 'LE');
        Assert.isTrue(DNAMSRuleEvaluator.satisfies('LT', '2', new List<Object>{ '3' }), 'LT');
        Assert.isTrue(DNAMSRuleEvaluator.satisfies('GT', '4', new List<Object>{ '3' }), 'GT');
        Assert.areEqual('"ABC" does not match "ABC LLC".', DNAMSRuleEvaluator.sentence('EQUALS', 'ABC', new List<Object>{ 'ABC LLC' }, false), 'Plain English');
        Assert.isTrue(DNAMSRuleEvaluator.sentence('GE', '2020-01-01', new List<Object>{ '{TODAY-90}' }, false).contains('too early'), 'Date wording');
        Assert.isTrue(DNAMSRuleEvaluator.sentence('IN', 'X', new List<Object>{ 'A', 'B' }, false).contains('"A" or "B"'), 'List wording');
        Assert.isTrue(DNAMSRuleEvaluator.sentence('NOT EQUALS', 'A', new List<Object>{ 'A' }, false).contains('should be different'), 'Not equals wording');
        Assert.areEqual('Signature Of Dealer Operator Present', DNAMSRuleEvaluator.fieldLabel('extraction.DealerApplication.isSignatureOfDealerOperatorPresent'), 'Field label');
        try {
            DNAMSRuleEvaluator.compare('abc', 'def');
            Assert.fail('Text cannot be ordered');
        } catch (DNAMSRuleEvaluator.NotComparableException expected) {
            Assert.isTrue(expected.getMessage().contains('abc'), expected.getMessage());
        }
    }

    @IsTest
    static void bandsKeysAndModelParsing() {
        Assert.areEqual('Green', DNAMSRuleValidationCompletionHelper.band(100), 'Green');
        Assert.areEqual('Green', DNAMSRuleValidationCompletionHelper.band(null), 'No applicable rule');
        Assert.areEqual('Amber', DNAMSRuleValidationCompletionHelper.band(85), 'Amber at 85');
        Assert.areEqual('Red', DNAMSRuleValidationCompletionHelper.band(84.99), 'Red below 85');
        Assert.areEqual(new List<String>{ 'a', 'b' }, DNAMSRuleUtil.parseKeys('["a","b"]'), 'JSON key list');
        Assert.areEqual(new List<String>{ '' }, DNAMSRuleUtil.parseKeys('\'\''), 'Quoted empty static');
        Assert.areEqual(new List<String>{ '[not json' }, DNAMSRuleUtil.parseKeys('[not json'), 'Literal starting with [');
        Map<String, Map<String, Object>> parsed = DNAMSAIRuleValidationQueueable.parse('Here: [{"rule_id":"R1","verdict":"FAIL"}] done');
        Assert.areEqual('FAIL', parsed.get('R1').get('verdict'), 'Array found inside text');
        try {
            DNAMSAIRuleValidationQueueable.parse('no array');
            Assert.fail('Not an array');
        } catch (DNAMSPipelineException expected) {
            Assert.isTrue(expected.getMessage().contains('JSON array'), expected.getMessage());
        }
    }

    @IsTest
    static void crashedRuleJobFailsRuleValidationNotExtraction() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = setUpRun();

            new DNAMSRuleUtil.StageFailureFinalizer(fixture.runId, 'TestJob').execute(new CrashedJobContext());

            AI_Package_Review_Run__c run = [
                SELECT ExtractionProcessingStatus__c, RuleValidationProcessingStatus__c
                FROM AI_Package_Review_Run__c
                WHERE Id = :fixture.runId
            ];
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_FAILED, run.RuleValidationProcessingStatus__c, 'Rule validation failed');
            Assert.areEqual(DNAMSPipelineConstants.RUN_STAGE_COMPLETED, run.ExtractionProcessingStatus__c, 'Extraction untouched');
            Assert.areEqual(
                1,
                [SELECT COUNT() FROM AIReviewErrorLog__c WHERE ReviewRun__c = :fixture.runId AND Stage__c = :DNAMSPipelineConstants.STAGE_RULE_VALIDATION],
                'Logged against rule validation'
            );
        }
    }
}
