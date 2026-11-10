/**
 * @description     Tests DNAMSRunChangeDetector (baseline selection, keys, finished-OK rules, file / extraction / rule
 *                  preview, reuse copies, change summary, summary gate) and the run mode recorded by
 *                  DNAMS_PackageReviewPipelineService when a review request arrives.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-09
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-09   Abhishek Dutta  Initial version
 **/
@IsTest
private class DNAMSRunChangeDetectorTest {
    private static final String DA = 'Dealer Application';
    private static final String OC = 'Org Chart';
    private static final String CLASSIFICATION = 'Classification';

    /**
     * @description A dealer, two element types and one Initiated Term Renewal package.
     **/
    @TestSetup
    static void setup() {
        Account dealer = new Account(Name = 'Dealer', AccountNumber = 'TCE00087');
        insert dealer;
        List<DNAMS_Element_Type__c> types = new List<DNAMS_Element_Type__c>{
            new DNAMS_Element_Type__c(Name = DA, Sort_Order__c = 1, Is_Required__c = true, Is_Active__c = true),
            new DNAMS_Element_Type__c(Name = OC, Sort_Order__c = 2, Is_Required__c = true, Is_Active__c = true)
        };
        insert types;
        DNAMSPipelineTestHelper.mapElementTypes('Term Renewal', types);
        insert new DNAMS_Package__c(Type__c = 'Term Renewal', Status__c = 'Initiated', Buying_Dealer__c = dealer.Id);
    }

    // ------------------------------------------------------------------ helpers

    private static Id packageId() {
        return [SELECT Id FROM DNAMS_Package__c LIMIT 1].Id;
    }

    private static Id elementId(String name) {
        return [SELECT Id FROM DNAMS_Package_Element__c WHERE Name = :name LIMIT 1].Id;
    }

    private static ContentVersion attach(String elementName, String title) {
        ContentVersion version = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf(title),
            FirstPublishLocationId = elementId(elementName)
        );
        insert version;
        return [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :version.Id];
    }

    private static AI_Package_Review_Run__c run(String status) {
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(Package__c = packageId(), Status__c = status, Started_At__c = System.now());
        insert run;
        return [SELECT Id, Name, Status__c FROM AI_Package_Review_Run__c WHERE Id = :run.Id];
    }

    private static AIReviewStageResult__c classificationRow(Id runId, String elementName, ContentVersion version, String status) {
        return new AIReviewStageResult__c(
            ReviewRun__c = runId,
            Stage__c = CLASSIFICATION,
            PackageElement__c = elementId(elementName),
            ElementType__c = elementName,
            DocumentTitle__c = 'doc.pdf',
            DocumentType__c = elementName,
            ContentDocumentId__c = version.ContentDocumentId,
            ContentVersionId__c = version.Id,
            Outcome__c = status == 'Error' ? 'Error' : 'Match',
            Confidence__c = 'FULLY',
            ProcessingStatus__c = status
        );
    }

    private static AIReviewStageResult__c extractionRow(Id runId, String elementName, ContentVersion version, String actionVersion) {
        return new AIReviewStageResult__c(
            ReviewRun__c = runId,
            Stage__c = DNAMSPipelineConstants.STAGE_EXTRACTION,
            PackageElement__c = elementId(elementName),
            ElementType__c = elementName,
            DocumentTitle__c = 'doc.pdf',
            DocumentType__c = elementName,
            ContentDocumentId__c = version.ContentDocumentId,
            ContentVersionId__c = version.Id,
            IDPActionName__c = 'DealerApplication',
            IDPActionId__c = 'action-1',
            IDPActionVersion__c = actionVersion,
            ProcessingStatus__c = DNAMSPipelineConstants.ROW_COMPLETED,
            SchemaValidationStatus__c = DNAMSPipelineConstants.SCHEMA_PASSED,
            RawStageResponseJSON__c = '{"fields":{}}',
            CallbackToken__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
            MuleSoftExecutionId__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
            CallbackPayload__c = '{"status":"SUCCEEDED"}',
            CallbackReceivedAt__c = System.now()
        );
    }

    private static AIReviewStageResult__c ruleRow(Id runId, String ruleId, String method, String verdict) {
        return new AIReviewStageResult__c(
            ReviewRun__c = runId,
            Stage__c = DNAMSPipelineConstants.STAGE_RULE_VALIDATION,
            RuleId__c = ruleId,
            ComparisonMethod__c = method,
            SourceValue__c = 'A',
            ReferenceValue__c = 'B',
            Verdict__c = verdict,
            RawStageResponseJSON__c = method == DNAMSPipelineConstants.METHOD_AI ? '{"verdict":"' + verdict + '"}' : null,
            ProcessingStatus__c = DNAMSPipelineConstants.ROW_COMPLETED
        );
    }

    private static DNAMSIDPWrapper.ActionConfig action(String version) {
        DNAMSIDPWrapper.ActionConfig config = new DNAMSIDPWrapper.ActionConfig();
        config.developerName = 'DealerApplication';
        config.documentType = DA;
        config.actionId = 'action-1';
        config.actionVersion = version;
        return config;
    }

    private static Map<String, DNAMSRunChangeDetector.FileChange> byTitle(List<DNAMSRunChangeDetector.FileChange> changes) {
        Map<String, DNAMSRunChangeDetector.FileChange> changeByTitle = new Map<String, DNAMSRunChangeDetector.FileChange>();
        for (DNAMSRunChangeDetector.FileChange change : changes) {
            changeByTitle.put(change.title, change);
        }
        return changeByTitle;
    }

    // ------------------------------------------------------------------ baseline and run creation

    @IsTest
    static void baselineIsLastNonDiscardedRun() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            AI_Package_Review_Run__c first = run('Completed');
            AI_Package_Review_Run__c second = run('Cancelled');
            run('Discarded');

            Assert.areEqual(second.Id, DNAMSRunChangeDetector.baselineFor(packageId(), null).Id, 'Newest non-Discarded run');
            Assert.areEqual(first.Id, DNAMSRunChangeDetector.baselineFor(packageId(), second.Id).Id, 'Excluded run is skipped');
            Assert.areEqual(second.Id, DNAMSRunChangeDetector.baselinesFor(new Set<Id>{ packageId() }).get(packageId()).Id, 'Bulk lookup');
            Assert.isTrue(DNAMSRunChangeDetector.baselinesFor(null).isEmpty(), 'No packages, no baselines');
        }
    }

    @IsTest
    static void changesOnlyRequestRecordsModeAndBaseline() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Id packageId = packageId();
            update new DNAMS_Package__c(Id = packageId, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
            Test.getEventBus().deliver();
            AI_Package_Review_Run__c first = [SELECT Id, Name, RerunMode__c, BaselineRun__c FROM AI_Package_Review_Run__c WHERE Package__c = :packageId];
            Assert.areEqual(DNAMSPipelineConstants.RERUN_MODE_ALL, first.RerunMode__c, 'A dealer submit (blank mode) runs All');
            Assert.isNull(first.BaselineRun__c, 'An All run has no baseline');
            update new AI_Package_Review_Run__c(Id = first.Id, Status__c = 'Completed');

            DNAMS_PackageReviewPipelineService.requestRerun(packageId, DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY);
            Test.getEventBus().deliver();

            AI_Package_Review_Run__c rerun = [
                SELECT RerunMode__c, BaselineRun__c, ChangeSummary__c, Trigger_Source__c, Status__c
                FROM AI_Package_Review_Run__c
                WHERE Package__c = :packageId AND Id != :first.Id
            ];
            Assert.areEqual('Running', rerun.Status__c, 'The re-run starts');
            Assert.areEqual(DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY, rerun.RerunMode__c, 'Mode from the event');
            Assert.areEqual(first.Id, rerun.BaselineRun__c, 'Baseline is the previous run');
            Assert.isTrue(rerun.ChangeSummary__c.contains(first.Name), rerun.ChangeSummary__c);
            Assert.areEqual(first.Id, DNAMSRunChangeDetector.baselineRunIdFor([SELECT Id FROM AI_Package_Review_Run__c WHERE Id != :first.Id].Id), 'Stages read the baseline');
            Assert.isNull(DNAMSRunChangeDetector.baselineRunIdFor(first.Id), 'An All run gives no baseline to stages');
        }
    }

    @IsTest
    static void changesOnlyWithoutEarlierRunFallsBackToAll() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Id packageId = packageId();
            update new DNAMS_Package__c(Id = packageId, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
            delete [SELECT Id FROM AI_Package_Review_Run__c];
            DNAMS_PackageReviewPipelineService.handleReviewRequests(new List<DNAMS_Package_Review_Requested__e>{
                new DNAMS_Package_Review_Requested__e(Package_Id__c = packageId, Trigger_Source__c = 'RMR Rerun', Mode__c = 'changes only')
            });

            AI_Package_Review_Run__c rerun = [SELECT RerunMode__c, BaselineRun__c, ChangeSummary__c FROM AI_Package_Review_Run__c WHERE Package__c = :packageId];
            Assert.areEqual(DNAMSPipelineConstants.RERUN_MODE_ALL, rerun.RerunMode__c, 'Nothing to compare with: All');
            Assert.isNull(rerun.BaselineRun__c, 'No baseline');
            Assert.isTrue(rerun.ChangeSummary__c.contains('no earlier run'), rerun.ChangeSummary__c);
            Assert.areEqual(DNAMSPipelineConstants.RERUN_MODE_ALL, DNAMSRunChangeDetector.normaliseMode(null), 'Blank is All');
            Assert.areEqual(DNAMSPipelineConstants.RERUN_MODE_ALL, DNAMSRunChangeDetector.normaliseMode('other'), 'Unknown is All');
        }
    }

    // ------------------------------------------------------------------ preview: files

    @IsTest
    static void previewWithoutBaselineHasNoChanges() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSRunChangeDetector.Preview preview = DNAMSRunChangeDetector.preview(packageId());
            Assert.isFalse(preview.hasBaseline, 'No run yet');
            Assert.isFalse(preview.hasChanges, 'Changes only is blocked');
            Assert.isTrue(preview.text.contains('Re-run all'), preview.text);
        }
    }

    @IsTest
    static void previewNothingChanged() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            ContentVersion version = attach(DA, 'same');
            AI_Package_Review_Run__c baseline = run('Completed');
            insert classificationRow(baseline.Id, DA, version, DNAMSPipelineConstants.ROW_COMPLETED);

            DNAMSRunChangeDetector.Preview preview = DNAMSRunChangeDetector.preview(packageId());

            Assert.isTrue(preview.hasBaseline, 'Baseline found');
            Assert.isFalse(preview.hasChanges, 'Same file, same version');
            Assert.areEqual(baseline.Name, preview.baselineRunName, 'Baseline name');
            Assert.areEqual('Nothing has changed since ' + baseline.Name + '. Use Re-run all to run everything again.', preview.text, 'Block message');
            Assert.areEqual(DNAMSRunChangeDetector.CHANGE_UNCHANGED, preview.fileChanges[0].kind, 'Unchanged file');
        }
    }

    @IsTest
    static void previewDetectsAddedRemovedNewVersionAndUnfinished() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            ContentVersion same = attach(DA, 'same');
            ContentVersion versioned = attach(DA, 'versioned');
            ContentVersion removed = attach(OC, 'removed');
            ContentVersion unfinished = attach(OC, 'unfinished');
            AI_Package_Review_Run__c baseline = run('Completed');
            insert new List<AIReviewStageResult__c>{
                classificationRow(baseline.Id, DA, same, DNAMSPipelineConstants.ROW_COMPLETED),
                classificationRow(baseline.Id, DA, versioned, DNAMSPipelineConstants.ROW_COMPLETED),
                classificationRow(baseline.Id, OC, removed, DNAMSPipelineConstants.ROW_COMPLETED),
                classificationRow(baseline.Id, OC, unfinished, DNAMSPipelineConstants.ROW_ERROR)
            };
            insert new ContentVersion(ContentDocumentId = versioned.ContentDocumentId, Title = 'versioned', PathOnClient = 'versioned.pdf', VersionData = Blob.valueOf('v2'));
            delete [SELECT Id FROM ContentDocument WHERE Id = :removed.ContentDocumentId];
            attach(OC, 'added');

            DNAMSRunChangeDetector.Preview preview = DNAMSRunChangeDetector.preview(packageId());
            Map<String, DNAMSRunChangeDetector.FileChange> changes = byTitle(preview.fileChanges);

            Assert.isTrue(preview.hasChanges, 'Files changed');
            Assert.areEqual(DNAMSRunChangeDetector.CHANGE_UNCHANGED, changes.get('same.pdf').kind, 'same');
            Assert.areEqual(same.Id, changes.get('same.pdf').baselineRow.ContentVersionId__c, 'Unchanged carries its baseline row');
            Assert.areEqual(DNAMSRunChangeDetector.CHANGE_NEW_VERSION, changes.get('versioned.pdf').kind, 'versioned');
            Assert.areEqual(DNAMSRunChangeDetector.CHANGE_ADDED, changes.get('added.pdf').kind, 'added');
            Assert.areEqual(DNAMSRunChangeDetector.CHANGE_UNFINISHED, changes.get('unfinished.pdf').kind, 'unfinished');
            Assert.areEqual(DNAMSRunChangeDetector.CHANGE_REMOVED, changes.get('doc.pdf').kind, 'removed (baseline title)');
            Assert.isTrue(preview.text.contains('new version'), preview.text);
            Assert.isTrue(preview.text.contains('Rules are re-checked after extraction.'), preview.text);
        }
    }

    @IsTest
    static void previewUnfinishedBaselineCountsAsChange() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            run('Cancelled');
            DNAMSRunChangeDetector.Preview preview = DNAMSRunChangeDetector.preview(packageId());
            Assert.isTrue(preview.hasChanges, 'A cancelled baseline runs again');
            Assert.isTrue(preview.text.contains('did not finish (Cancelled)'), preview.text);
        }
    }

    // ------------------------------------------------------------------ preview: extraction and rules

    @IsTest
    static void previewDetectsIdpVersionChange() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            ContentVersion version = attach(DA, 'app');
            AI_Package_Review_Run__c baseline = run('Completed');
            update new AI_Package_Review_Run__c(Id = baseline.Id, ExtractionProcessingStatus__c = 'Completed');
            insert new List<AIReviewStageResult__c>{
                classificationRow(baseline.Id, DA, version, DNAMSPipelineConstants.ROW_COMPLETED),
                extractionRow(baseline.Id, DA, version, '1.0.0')
            };
            DNAMSIDPActionUtil.actionsOverride = new Map<String, DNAMSIDPWrapper.ActionConfig>{ DA.toLowerCase() => action('1.0.0') };
            Assert.isFalse(DNAMSRunChangeDetector.preview(packageId()).hasChanges, 'Same IDP action version');

            DNAMSIDPActionUtil.actionsOverride = new Map<String, DNAMSIDPWrapper.ActionConfig>{ DA.toLowerCase() => action('2.0.0') };
            DNAMSRunChangeDetector.Preview preview = DNAMSRunChangeDetector.preview(packageId());

            Assert.isTrue(preview.hasChanges, 'New IDP action version');
            Assert.isTrue(preview.text.contains('IDP action version 1.0.0 -> 2.0.0'), preview.text);
        }
    }

    @IsTest
    static void previewDetectsRuleValueAndPirChanges() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSRule__mdt rule = new DNAMSRule__mdt(
                DeveloperName = 'DA_T01', MasterLabel = 'Dealer code', RuleType__c = 'Validation', ValidationMethod__c = 'ExactMatch',
                RuleAppliedTo__c = 'Element', RelativeElementType__c = DA, SourceFieldType__c = 'Record',
                SourceFieldKey__c = 'Package.Buying_Dealer__r.AccountNumber', Comparator__c = 'EQUALS',
                ReferenceFieldType__c = 'Static', ReferenceFieldKey__c = 'TCE00087', IsActive__c = true
            );
            DNAMSRuleUtil.rulesOverride = new List<DNAMSRule__mdt>{ rule };
            Id packageId = packageId();
            DNAMSRuleEvaluator.Outcome outcome = new DNAMSRuleEvaluator(packageId, '{}').evaluate(rule);
            DNAMS_Package__c pkg = [SELECT PIR_Linked__c, PIR_Cleared__c, PIR_Bypass_Acknowledged__c FROM DNAMS_Package__c WHERE Id = :packageId];
            AI_Package_Review_Run__c baseline = run('Completed');
            update new AI_Package_Review_Run__c(
                Id = baseline.Id, ExtractionProcessingStatus__c = 'Completed', RuleValidationProcessingStatus__c = 'Completed', ConsolidatedExtractionJSON__c = '{}'
            );
            AIReviewStageResult__c ruleRow = ruleRow(baseline.Id, 'DA_T01', DNAMSPipelineConstants.METHOD_EXACT, 'PASS');
            ruleRow.SourceValue__c = outcome.sourceValue;
            ruleRow.ReferenceValue__c = outcome.referenceValue;
            AIReviewStageResult__c pirRow = ruleRow(baseline.Id, DNAMSPipelineConstants.PIR_RULE_ID, DNAMSPipelineConstants.METHOD_PIR, 'NOT_APPLICABLE');
            pirRow.SourceValue__c = DNAMSRunChangeDetector.pirSourceValue(pkg);
            insert new List<AIReviewStageResult__c>{ ruleRow, pirRow };
            Assert.isFalse(DNAMSRunChangeDetector.preview(packageId).hasChanges, 'Same rule values and PIR');

            update new Account(Id = [SELECT Buying_Dealer__c FROM DNAMS_Package__c WHERE Id = :packageId].Buying_Dealer__c, AccountNumber = 'TCE99999');
            update new DNAMS_Package__c(Id = packageId, PIR_Linked__c = true);
            DNAMSRunChangeDetector.Preview preview = DNAMSRunChangeDetector.preview(packageId);

            Assert.isTrue(preview.hasChanges, 'Record value and PIR changed');
            Assert.isTrue(preview.text.contains('Rule values changed: DA_T01'), preview.text);
            Assert.isTrue(preview.text.contains('PIR status changed.'), preview.text);
        }
    }

    // ------------------------------------------------------------------ reusable rows, validity, keys

    @IsTest
    static void reusableRowsFollowFinishedRules() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            ContentVersion good = attach(DA, 'good');
            ContentVersion bad = attach(OC, 'bad');
            AI_Package_Review_Run__c baseline = run('Completed');
            AIReviewStageResult__c schemaFailed = extractionRow(baseline.Id, OC, bad, '1.0.0');
            schemaFailed.SchemaValidationStatus__c = DNAMSPipelineConstants.SCHEMA_FAILED;
            AIReviewStageResult__c aiFailedCall = ruleRow(baseline.Id, 'R3', DNAMSPipelineConstants.METHOD_AI, 'CANNOT_DECIDE');
            aiFailedCall.RawStageResponseJSON__c = null;
            insert new List<AIReviewStageResult__c>{
                classificationRow(baseline.Id, DA, good, DNAMSPipelineConstants.ROW_COMPLETED),
                classificationRow(baseline.Id, OC, bad, DNAMSPipelineConstants.ROW_ERROR),
                extractionRow(baseline.Id, DA, good, '1.0.0'),
                schemaFailed,
                ruleRow(baseline.Id, 'R1', DNAMSPipelineConstants.METHOD_AI, 'FAIL'),
                ruleRow(baseline.Id, 'R2', DNAMSPipelineConstants.METHOD_EXACT, 'PASS'),
                aiFailedCall
            };
            String goodKey = DNAMSRunChangeDetector.fileKey(elementId(DA), good.ContentDocumentId, good.Id);

            Map<String, AIReviewStageResult__c> classification = DNAMSRunChangeDetector.reusableClassificationRows(baseline.Id);
            Map<String, AIReviewStageResult__c> extraction = DNAMSRunChangeDetector.reusableExtractionRows(baseline.Id);
            Map<String, AIReviewStageResult__c> rules = DNAMSRunChangeDetector.reusableRuleRows(baseline.Id);

            Assert.areEqual(new Set<String>{ goodKey }, classification.keySet(), 'Error rows are not reusable');
            Assert.areEqual(new Set<String>{ goodKey }, extraction.keySet(), 'Schema failures are not reusable');
            Assert.areEqual(new Set<String>{ 'R1' }, rules.keySet(), 'Only finished AIMatch rows (a FAIL is reused)');
            Assert.isTrue(DNAMSRunChangeDetector.ruleStillValid(rules.get('R1'), 'A', 'B'), 'Same values');
            Assert.isFalse(DNAMSRunChangeDetector.ruleStillValid(rules.get('R1'), 'A', 'b'), 'Values compare case-sensitively');
            Assert.isFalse(DNAMSRunChangeDetector.ruleStillValid(null, 'A', 'B'), 'No baseline row');

            AIReviewStageResult__c row = extraction.get(goodKey);
            Assert.isTrue(DNAMSRunChangeDetector.extractionStillValid(row, DA.toUpperCase(), action('1.0.0')), 'Type compares case-insensitively');
            Assert.isFalse(DNAMSRunChangeDetector.extractionStillValid(row, OC, action('1.0.0')), 'Type changed');
            Assert.isFalse(DNAMSRunChangeDetector.extractionStillValid(row, DA, null), 'No action any more');
            Assert.isFalse(DNAMSRunChangeDetector.extractionStillValid(row, DA, action('1.1.0')), 'Version changed');
            DNAMSIDPWrapper.ActionConfig renamed = action('1.0.0');
            renamed.actionId = 'action-2';
            Assert.isTrue(DNAMSRunChangeDetector.extractionChangeReason(row, DA, renamed).startsWith('IDP action'), 'Action changed');
            Assert.areEqual('not extracted before', DNAMSRunChangeDetector.extractionChangeReason(null, DA, action('1.0.0')), 'No row');
            Assert.areEqual('R1', DNAMSRunChangeDetector.ruleKey(rules.get('R1')), 'Rule key');
            Assert.areEqual(goodKey, DNAMSRunChangeDetector.fileKey(row), 'Row key equals file key');
        }
    }

    @IsTest
    static void cloneForReuseCopiesResultAndClearsCallbackFields() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            ContentVersion version = attach(DA, 'app');
            AI_Package_Review_Run__c baseline = run('Completed');
            AIReviewStageResult__c original = extractionRow(baseline.Id, DA, version, '1.0.0');
            insert original;
            AI_Package_Review_Run__c second = run('Running');
            AI_Package_Review_Run__c third = run('Running');

            AIReviewStageResult__c copy = DNAMSRunChangeDetector.cloneForReuse(
                DNAMSRunChangeDetector.stageRows(baseline.Id, DNAMSPipelineConstants.STAGE_EXTRACTION)[0], second.Id
            );
            insert copy;
            AIReviewStageResult__c copyOfCopy = DNAMSRunChangeDetector.cloneForReuse(
                DNAMSRunChangeDetector.stageRows(second.Id, DNAMSPipelineConstants.STAGE_EXTRACTION), third.Id
            )[0];
            insert copyOfCopy;

            AIReviewStageResult__c saved = [
                SELECT ReviewRun__c, ReusedFromResult__c, ProcessingStatus__c, SchemaValidationStatus__c, RawStageResponseJSON__c,
                    IDPActionVersion__c, ContentVersionId__c, CallbackToken__c, MuleSoftExecutionId__c, CallbackPayload__c, CallbackReceivedAt__c
                FROM AIReviewStageResult__c
                WHERE Id = :copy.Id
            ];
            Assert.areEqual(second.Id, saved.ReviewRun__c, 'Copied into the new run');
            Assert.areEqual(original.Id, saved.ReusedFromResult__c, 'Linked to the original');
            Assert.areEqual(DNAMSPipelineConstants.ROW_COMPLETED, saved.ProcessingStatus__c, 'Terminal status kept');
            Assert.areEqual('{"fields":{}}', saved.RawStageResponseJSON__c, 'Payload copied');
            Assert.areEqual(String.valueOf(version.Id), saved.ContentVersionId__c, 'Unit fields copied');
            Assert.isNull(saved.CallbackToken__c, 'Callback token cleared');
            Assert.isNull(saved.MuleSoftExecutionId__c, 'Execution id cleared');
            Assert.isNull(saved.CallbackPayload__c, 'Callback payload cleared');
            Assert.isNull(saved.CallbackReceivedAt__c, 'Callback time cleared');
            Assert.areEqual(original.Id, [SELECT ReusedFromResult__c FROM AIReviewStageResult__c WHERE Id = :copyOfCopy.Id].ReusedFromResult__c, 'A copy of a copy points to the original');
        }
    }

    // ------------------------------------------------------------------ change summary and summary gate

    @IsTest
    static void appendChangeSummaryAddsLines() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            AI_Package_Review_Run__c newRun = run('Running');
            DNAMSRunChangeDetector.appendChangeSummary(newRun.Id, DNAMSRunChangeDetector.SUMMARY_CLASSIFICATION,
                DNAMSRunChangeDetector.stageLine(2, 1, new List<String>{ 'Org Chart / chart.pdf: new version' }));
            DNAMSRunChangeDetector.appendChangeSummary(newRun.Id, DNAMSRunChangeDetector.SUMMARY_EXTRACTION, DNAMSRunChangeDetector.stageLine(3, 0, null));

            Assert.areEqual(
                'Classification: 2 reused, 1 re-run (Org Chart / chart.pdf: new version)\nExtraction: 3 reused, 0 re-run',
                [SELECT ChangeSummary__c FROM AI_Package_Review_Run__c WHERE Id = :newRun.Id].ChangeSummary__c,
                'One line per stage'
            );
        }
    }

    @IsTest
    static void summaryNeededOnlyWhenSomethingChanged() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            ContentVersion version = attach(DA, 'app');
            AI_Package_Review_Run__c baseline = run('Completed');
            List<AIReviewStageResult__c> baselineRows = new List<AIReviewStageResult__c>{
                classificationRow(baseline.Id, DA, version, DNAMSPipelineConstants.ROW_COMPLETED),
                ruleRow(baseline.Id, 'R1', DNAMSPipelineConstants.METHOD_AI, 'PASS'),
                ruleRow(baseline.Id, 'R2', DNAMSPipelineConstants.METHOD_EXACT, 'PASS')
            };
            insert baselineRows;
            AI_Package_Review_Run__c newRun = run('Running');
            Assert.isTrue(DNAMSRunChangeDetector.summaryNeeded(newRun.Id), 'An All run always redrafts');

            update new AI_Package_Review_Run__c(Id = newRun.Id, RerunMode__c = 'Changes Only', BaselineRun__c = baseline.Id);
            List<AIReviewStageResult__c> reused = DNAMSRunChangeDetector.cloneForReuse(
                new List<AIReviewStageResult__c>{
                    DNAMSRunChangeDetector.stageRows(baseline.Id, CLASSIFICATION)[0],
                    DNAMSRunChangeDetector.reusableRuleRows(baseline.Id).get('R1')
                },
                newRun.Id
            );
            AIReviewStageResult__c exact = ruleRow(newRun.Id, 'R2', DNAMSPipelineConstants.METHOD_EXACT, 'PASS');
            insert reused;
            insert exact;
            Assert.isFalse(DNAMSRunChangeDetector.summaryNeeded(newRun.Id), 'Everything reused and the same verdicts');

            // ReviewRun__c (master-detail) is not updateable: update a fresh record with only the changed field
            update new AIReviewStageResult__c(Id = exact.Id, Verdict__c = 'FAIL');
            Assert.isTrue(DNAMSRunChangeDetector.summaryNeeded(newRun.Id), 'An ExactMatch verdict changed');

            update new AIReviewStageResult__c(Id = exact.Id, Verdict__c = 'PASS');
            insert ruleRow(newRun.Id, 'R9', DNAMSPipelineConstants.METHOD_AI, 'PASS');
            Assert.isTrue(DNAMSRunChangeDetector.summaryNeeded(newRun.Id), 'An AIMatch rule ran again');
        }
    }

    @IsTest
    static void summaryNeededWhenPreflightIssuesDiffer() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            String preflight = 'Pre-flight file check stopped the review before any AI step.\n';
            AI_Package_Review_Run__c baseline = run('Completed');
            update new AI_Package_Review_Run__c(Id = baseline.Id, Issue_Summary__c = preflight + '- Org Chart / chart.docx [Invalid File Type]: not a PDF');
            AI_Package_Review_Run__c newRun = run('Completed');
            update new AI_Package_Review_Run__c(
                Id = newRun.Id,
                RerunMode__c = 'Changes Only',
                BaselineRun__c = baseline.Id,
                Issue_Summary__c = preflight + '- Org Chart / chart.docx [Invalid File Type]: not a PDF'
            );

            Test.startTest();
            Boolean sameProblems = DNAMSRunChangeDetector.summaryNeeded(newRun.Id);
            update new AI_Package_Review_Run__c(Id = newRun.Id, Issue_Summary__c = preflight + '- Dealer Application / app.pdf [File Too Large]: over 3 MB');
            Boolean otherProblems = DNAMSRunChangeDetector.summaryNeeded(newRun.Id);
            Test.stopTest();

            Assert.isFalse(sameProblems, 'Both runs stopped at pre-flight with the same file problems');
            Assert.isTrue(otherProblems, 'Both runs stopped at pre-flight (no stage rows) but the file problems differ');
        }
    }
}
