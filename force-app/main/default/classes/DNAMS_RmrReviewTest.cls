/**
 * @description     Tests the RMR actions (Cancel / Re-run review, Return to Dealer) and the package narrative with its
 *                  RMR notification. RMR actions run as an inserted RMR user (System Administrator + DNAMS_Package_Access
 *                  + DNAMS_RMR), so the result does not depend on the permission sets of whoever runs the tests.
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-10
 * @last modified by Abhishek Dutta
 * @last modification details Re-run changes only: preview in the check, mode passed to the run, server-side refusal
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-10-20   Sachin Mondal   Initial version
 * 1.1   2026-11-03   Abhishek Dutta  PMD clean-up; System.runAs with an inserted RMR user
 * 1.2   2026-11-10   Abhishek Dutta  Re-run changes only tests
 **/
// Exception to guideline: the DNAMS_ prefix is the project's class naming standard for this module
@SuppressWarnings('PMD.ClassNamingConventions')
@IsTest
public class DNAMS_RmrReviewTest {
    /**
     * @description "good*" -> FULLY match; anything else -> FULLY wrong type.
     **/
    private class StubClassifier implements DNAMS_DocumentClassifier {
        /**
         * @description Returns the canned model answer for the file's title.
         * @param promptTemplate    Prompt template name (unused)
         * @param contentDocumentId File being classified
         * @param elementId         Package element the file belongs to
         * @return                  Model response text
         **/
        public String classify(String promptTemplate, Id contentDocumentId, Id elementId) {
            String title = [SELECT Title FROM ContentDocument WHERE Id = :contentDocumentId].Title;
            String expected = [SELECT Name FROM DNAMS_Package_Element__c WHERE Id = :elementId].Name;
            return title.startsWith('good')
                ? '{"matches_expected": true, "document_type": "' + expected + '", "confidence": "FULLY", "reasoning": "clear"}'
                : '{"matches_expected": false, "document_type": "Bank Statement", "confidence": "FULLY", "reasoning": "a statement"}';
        }
    }

    /**
     * @description Narrative writer stub; throws when fail is set.
     **/
    private class StubWriter implements DNAMS_NarrativeWriter {
        Boolean fail = false;

        /**
         * @description Returns a fixed narrative or throws like a model outage.
         * @param promptTemplate Prompt template name (unused)
         * @param factsJson      Run facts (unused)
         * @return               Summary JSON, wrapped in a code fence like a real model answer
         **/
        public String write(String promptTemplate, String factsJson) {
            if (fail) {
                throw new DNAMS_PackageReviewPipelineService.PipelineException('model down');
            }
            return '```json\n{"headline": "One element needs a new document", "overall_health": "GREEN", "summary": "The Org Chart is wrong.", '
                + '"elements": [{"element": "Org Chart", "status": "failed", "findings": ["A bank statement was uploaded instead of the ownership chart."], '
                + '"dealer_action": "Upload the signed org chart."}], "next_steps": ["Return the package to the dealer."]}\n```';
        }
    }

    /**
     * @description Inserts an RMR user: System Administrator with DNAMS_Package_Access and DNAMS_RMR. Call before any
     *              non-setup DML in the test and use the user in System.runAs (avoids MIXED_DML).
     * @return The inserted user
     * @example
     *   User rmrUser = DNAMS_RmrReviewTest.createRmrUser();
     *   System.runAs(rmrUser) { ... }
     **/
    public static User createRmrUser() {
        User rmrUser = DNAMSPipelineTestHelper.getAdminUser();
        Id permissionSetId = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = :DNAMS_PackageReviewPipelineService.RMR_PERMISSION
            WITH SYSTEM_MODE
            LIMIT 1
        ].Id;
        Database.insert(new PermissionSetAssignment(AssigneeId = rmrUser.Id, PermissionSetId = permissionSetId), AccessLevel.SYSTEM_MODE);
        return rmrUser;
    }

    /**
     * @description A dealer with a principal contact, two required element types and one Initiated package.
     **/
    @TestSetup
    static void setup() {
        Account dealer = new Account(Name = 'Dealer', AccountNumber = 'TCE00087');
        insert dealer;
        Contact principal = new Contact(LastName = 'Principal', AccountId = dealer.Id, Email = 'principal@example.com');
        insert principal;
        List<DNAMS_Element_Type__c> types = new List<DNAMS_Element_Type__c>{
            new DNAMS_Element_Type__c(Name = 'Dealer Application', Sort_Order__c = 1, Is_Required__c = true),
            new DNAMS_Element_Type__c(Name = 'Org Chart', Sort_Order__c = 2, Is_Required__c = true)
        };
        insert types;
        DNAMSPipelineTestHelper.mapElementTypes('Term Renewal', types);
        insert new DNAMS_Package__c(Type__c = 'Term Renewal', Status__c = 'Initiated', Buying_Dealer__c = dealer.Id, Primary_Contact__c = principal.Id);
    }

    /**
     * @description Installs the classifier and narrative stubs and in-memory pipeline settings.
     * @return The narrative writer stub
     **/
    private static StubWriter useStubs() {
        DNAMS_DocumentClassificationBatch.classifier = new StubClassifier();
        StubWriter writer = new StubWriter();
        DNAMS_PackageNarrativeQueueable.writer = writer;
        DNAMS_PackageReviewPipelineService.settingsOverride = new DNAMS_Pipeline_Setting__mdt(
            Batch_Size__c = 10,
            Max_Attempts__c = 1,
            Min_Accepted_Confidence__c = 'MODERATE',
            Min_Auto_Accept_Confidence__c = 'FULLY',
            Prompt_Template__c = 'DNAMS_DocumentClassifier_Prompt',
            Narrative_Prompt_Template__c = 'DNAMS_PackageIssueNarrator_Prompt'
        );
        return writer;
    }

    /**
     * @description The single test package.
     * @return The package with status, health, narrative and upload link recipient
     **/
    private static DNAMS_Package__c pkg() {
        return [SELECT Id, Status__c, Health__c, AI_Narrative__c, Upload_Link_Sent_To__c FROM DNAMS_Package__c LIMIT 1];
    }

    /**
     * @description Uploads a small file to the named element.
     * @param elementName Element name
     * @param title       File title (drives the stub's answer)
     **/
    private static void attach(String elementName, String title) {
        Id elementId = [SELECT Id FROM DNAMS_Package_Element__c WHERE Name = :elementName].Id;
        insert new ContentVersion(Title = title, PathOnClient = title + '.pdf', VersionData = Blob.valueOf(title), FirstPublishLocationId = elementId);
    }

    /**
     * @description Completes every run of the test package, so a new request is not a duplicate.
     **/
    private static void completeRuns() {
        List<AI_Package_Review_Run__c> runs = [SELECT Id FROM AI_Package_Review_Run__c WHERE Package__c = :pkg().Id];
        for (AI_Package_Review_Run__c run : runs) {
            run.Status__c = 'Completed';
        }
        update runs;
    }

    /**
     * @description Submits (override), retires the event's run, then classifies with the stub.
     * @return The classified run
     **/
    private static AI_Package_Review_Run__c submitAndClassify() {
        update new DNAMS_Package__c(Id = pkg().Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
        Test.getEventBus().deliver();
        completeRuns();
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(Package__c = pkg().Id, Status__c = 'Running', Started_At__c = System.now());
        insert run;
        Test.startTest();
        new DNAMS_ClassificationStarterQueueable(run.Id).execute(null);
        Test.stopTest();
        return run;
    }

    /**
     * @description Re-reads a run.
     * @param runId Run id
     * @return The run with its status fields
     **/
    private static AI_Package_Review_Run__c reload(Id runId) {
        return [SELECT Status__c, Overall_Result__c, Reason__c, Error__c FROM AI_Package_Review_Run__c WHERE Id = :runId];
    }

    /**
     * @description Calls the Cancel Review invocable as the flow does.
     * @param packageId Package id
     * @return Message for the flow screen
     **/
    private static String cancelViaFlow(Id packageId) {
        DNAMS_CancelReviewAction.Request request = new DNAMS_CancelReviewAction.Request();
        request.packageId = packageId;
        return DNAMS_CancelReviewAction.run(new List<DNAMS_CancelReviewAction.Request>{ request })[0].message;
    }

    /**
     * @description Calls the Re-run Review invocable as the flow does.
     * @param packageId Package id
     * @return Message for the flow screen
     **/
    private static String rerunViaFlow(Id packageId) {
        return rerunViaFlow(packageId, null);
    }

    /**
     * @description Calls the Re-run Review invocable with the mode chosen on the flow's Confirm screen.
     * @param packageId Package id
     * @param mode      Changes Only, All or blank (= All)
     * @return Message for the flow screen
     **/
    private static String rerunViaFlow(Id packageId, String mode) {
        DNAMS_RerunReviewAction.Request request = new DNAMS_RerunReviewAction.Request();
        request.packageId = packageId;
        request.mode = mode;
        return DNAMS_RerunReviewAction.run(new List<DNAMS_RerunReviewAction.Request>{ request })[0].message;
    }

    /**
     * @description Submits the package (override) and completes the run the submit started, which becomes the
     *              baseline of a Changes Only re-run.
     * @return The completed baseline run with its name
     **/
    private static AI_Package_Review_Run__c submitAndCompleteBaseline() {
        update new DNAMS_Package__c(Id = pkg().Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
        Test.getEventBus().deliver();
        completeRuns();
        return [SELECT Id, Name FROM AI_Package_Review_Run__c WHERE Package__c = :pkg().Id ORDER BY CreatedDate DESC LIMIT 1];
    }

    /**
     * @description The RMR Rerun runs started by delivered re-run requests.
     * @return Runs with their re-run mode and baseline
     **/
    private static List<AI_Package_Review_Run__c> rerunRuns() {
        return [
            SELECT Id, RerunMode__c, BaselineRun__c, ChangeSummary__c
            FROM AI_Package_Review_Run__c
            WHERE Trigger_Source__c = :DNAMS_PackageReviewPipelineService.SOURCE_RMR_RERUN
        ];
    }

    /**
     * @description Calls the Initiate Package/Return to Dealer invocable as the flow does.
     * @param packageId Package id
     * @return Message for the flow screen
     **/
    private static String sendReturnViaFlow(Id packageId) {
        DNAMS_ReturnToDealerAction.Request request = new DNAMS_ReturnToDealerAction.Request();
        request.packageId = packageId;
        return DNAMS_ReturnToDealerAction.run(new List<DNAMS_ReturnToDealerAction.Request>{ request })[0].message;
    }

    /**
     * @description Calls the availability check as the Re-run / Cancel flows do before their confirmation screen.
     * @param packageId Package id
     * @param action    Rerun or Cancel
     * @return The check result
     **/
    private static DNAMS_ReviewActionCheck.Result checkViaFlow(Id packageId, String action) {
        DNAMS_ReviewActionCheck.Request request = new DNAMS_ReviewActionCheck.Request();
        request.packageId = packageId;
        request.action = action;
        return DNAMS_ReviewActionCheck.check(new List<DNAMS_ReviewActionCheck.Request>{ request })[0];
    }

    // ------------------------------------------------------------------ 1b cancel / re-run

    /**
     * @description The modals' first step: confirm only when the action is possible, otherwise explain why at once.
     **/
    @IsTest
    static void checkActionExplainsBeforeConfirming() {
        System.runAs(createRmrUser()) {
            DNAMS_ReviewActionCheck.Result cancelNothing = checkViaFlow(pkg().Id, 'Cancel');
            Assert.isFalse(cancelNothing.canProceed, 'Nothing to cancel');
            Assert.isTrue(cancelNothing.message.contains('No AI review is running'), cancelNothing.message);
            DNAMS_ReviewActionCheck.Result rerunBeforeSubmit = checkViaFlow(pkg().Id, 'Rerun');
            Assert.isFalse(rerunBeforeSubmit.canProceed, 'Not submitted yet');
            Assert.isTrue(rerunBeforeSubmit.message.contains('Initiated'), rerunBeforeSubmit.message);

            update new DNAMS_Package__c(Id = pkg().Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
            delete [SELECT Id FROM AI_Package_Review_Run__c];
            DNAMS_ReviewActionCheck.Result rerunIdle = checkViaFlow(pkg().Id, 'Rerun');
            Assert.isTrue(rerunIdle.canProceed, rerunIdle.message);
            Assert.isTrue(rerunIdle.message.contains('run the AI document review again'), rerunIdle.message);

            AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(Package__c = pkg().Id, Status__c = 'Running');
            insert run;
            String runName = [SELECT Name FROM AI_Package_Review_Run__c WHERE Id = :run.Id].Name;
            DNAMS_ReviewActionCheck.Result cancelRunning = checkViaFlow(pkg().Id, 'Cancel');
            Assert.isTrue(cancelRunning.canProceed, cancelRunning.message);
            Assert.isTrue(cancelRunning.message.contains(runName), cancelRunning.message);
            DNAMS_ReviewActionCheck.Result rerunWhileRunning = checkViaFlow(pkg().Id, 'Rerun');
            Assert.isFalse(rerunWhileRunning.canProceed, 'A review is running');
            Assert.isTrue(rerunWhileRunning.message.contains('still in progress'), rerunWhileRunning.message);
        }
    }

    /**
     * @description Cancel marks the running run Cancelling; a second cancel finds nothing in progress.
     **/
    @IsTest
    static void cancelRunningRunMarksCancelling() {
        System.runAs(createRmrUser()) {
            update new DNAMS_Package__c(Id = pkg().Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
            AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(Package__c = pkg().Id, Status__c = 'Running');
            insert run;

            String message = cancelViaFlow(pkg().Id);

            Assert.isTrue(message.contains('being cancelled'), message);
            Assert.areEqual('Cancelling', reload(run.Id).Status__c, 'Run is marked Cancelling');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.PACKAGE_RMR_PENDING, pkg().Status__c, 'Cancel moves the package to RMR Pending');
            String again = cancelViaFlow(pkg().Id);
            Assert.isTrue(again.contains('no review in progress'), again);
        }
    }

    /**
     * @description Re-run is blocked before submit; after submit it publishes a request that starts an RMR Rerun run.
     **/
    @IsTest
    static void rerunOnlyAfterSubmitAndPublishesRequest() {
        useStubs();
        System.runAs(createRmrUser()) {
            String blocked = rerunViaFlow(pkg().Id);
            Assert.isTrue(blocked.contains('Re-run is not available') && blocked.contains('Initiated'), blocked);

            update new DNAMS_Package__c(Id = pkg().Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
            Test.getEventBus().deliver();
            completeRuns();

            String requested = rerunViaFlow(pkg().Id);
            Assert.isTrue(requested.contains('new AI review was requested'), requested);
            Test.getEventBus().deliver();

            Assert.areEqual(
                1,
                [SELECT COUNT() FROM AI_Package_Review_Run__c WHERE Trigger_Source__c = 'RMR Rerun' AND Status__c = 'Running'],
                'The re-run request starts one RMR Rerun run'
            );
            Assert.areEqual(DNAMS_PackageReviewPipelineService.PACKAGE_UNDER_REVIEW, pkg().Status__c, 'The started re-run moves the package to Under Review');
            AI_Package_Review_Run__c rerun = rerunRuns()[0];
            Assert.areEqual(DNAMSPipelineConstants.RERUN_MODE_ALL, rerun.RerunMode__c, 'A re-run without a mode is Re-run all');
            Assert.isNull(rerun.BaselineRun__c, 'Re-run all has no baseline');
        }
    }

    /**
     * @description Nothing changed since the last run: the check offers only Re-run all with the block message, and a
     *              Changes Only request is refused on the server; Re-run all still works.
     **/
    @IsTest
    static void rerunChangesOnlyRefusedWhenNothingChanged() {
        useStubs();
        System.runAs(createRmrUser()) {
            AI_Package_Review_Run__c baseline = submitAndCompleteBaseline();

            DNAMS_ReviewActionCheck.Result check = checkViaFlow(pkg().Id, 'Rerun');
            Assert.isTrue(check.canProceed, check.message);
            Assert.areEqual('Do you want to run the AI document review again?', check.message, 'Confirm wording unchanged');
            Assert.isFalse(check.hasChanges, check.changePreview);
            Assert.areEqual(baseline.Name, check.baselineRunName, 'Compared with the last run');
            Assert.areEqual(
                'Nothing has changed since ' + baseline.Name + '. Use Re-run all to run everything again.',
                check.changePreview,
                'Block message from the preview'
            );

            String refused = rerunViaFlow(pkg().Id, DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY);
            Test.getEventBus().deliver();
            Assert.isTrue(refused.startsWith('Not done: Nothing has changed since ' + baseline.Name), refused);
            Assert.isTrue(rerunRuns().isEmpty(), 'A refused Changes Only re-run publishes nothing');

            String all = rerunViaFlow(pkg().Id, DNAMSPipelineConstants.RERUN_MODE_ALL);
            Test.getEventBus().deliver();
            Assert.areEqual('A new AI review was requested. It appears in AI Review Runs within a minute.', all, 'Re-run all message unchanged');
            Assert.areEqual(DNAMSPipelineConstants.RERUN_MODE_ALL, rerunRuns()[0].RerunMode__c, 'Re-run all run');
        }
    }

    /**
     * @description A file added since the last run: the check returns the preview, and Changes Only starts a run that
     *              records its mode and baseline.
     **/
    @IsTest
    static void rerunChangesOnlyPassesModeAndBaseline() {
        useStubs();
        System.runAs(createRmrUser()) {
            attach('Dealer Application', 'good application');
            AI_Package_Review_Run__c baseline = submitAndCompleteBaseline();

            DNAMS_ReviewActionCheck.Result check = checkViaFlow(pkg().Id, 'Rerun');
            Assert.isTrue(check.canProceed, check.message);
            Assert.isTrue(check.hasChanges, check.changePreview);
            Assert.areEqual(baseline.Name, check.baselineRunName, 'Compared with the last run');
            Assert.isTrue(check.changePreview.startsWith('Compared with ' + baseline.Name + ':<br>- '), check.changePreview);
            Assert.isTrue(check.changePreview.contains('good application'), check.changePreview);

            String requested = rerunViaFlow(pkg().Id, DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY);
            Assert.areEqual('A new AI review (changes only) was requested. It appears in AI Review Runs within a minute.', requested, 'Mode in the result');
            Test.getEventBus().deliver();

            List<AI_Package_Review_Run__c> runs = rerunRuns();
            Assert.areEqual(1, runs.size(), 'One re-run started');
            Assert.areEqual(DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY, runs[0].RerunMode__c, 'Mode passed to the run');
            Assert.areEqual(baseline.Id, runs[0].BaselineRun__c, 'Baseline is the last run');
        }
    }

    /**
     * @description Re-run is available from every post-submit status (Review Failed, Review Passed, RMR Pending, ...)
     *              when no review is active.
     **/
    @IsTest
    static void rerunAllowedFromReviewOutcomes() {
        System.runAs(createRmrUser()) {
            for (String status : new List<String>{
                DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_FAILED,
                DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_PASSED,
                DNAMS_PackageReviewPipelineService.PACKAGE_RMR_PENDING,
                DNAMS_PackageReviewPipelineService.PACKAGE_UNDER_REVIEW
            }) {
                update new DNAMS_Package__c(Id = pkg().Id, Status__c = status);
                DNAMS_ReviewActionCheck.Result check = checkViaFlow(pkg().Id, 'Rerun');
                Assert.isTrue(check.canProceed, status + ': ' + check.message);
            }
            update new DNAMS_Package__c(Id = pkg().Id, Status__c = 'Closed');
            DNAMS_ReviewActionCheck.Result closed = checkViaFlow(pkg().Id, 'Rerun');
            Assert.isFalse(closed.canProceed, 'Closed packages cannot be re-run');
        }
    }

    // ------------------------------------------------------------------ 21 return to dealer

    /**
     * @description Return needs the first send in History and an email; it sets Returned, stamps the send and shows element issues on the dealer page.
     **/
    @IsTest
    static void returnToDealerSetsReturnedAndEmailsLink() {
        useStubs();
        System.runAs(createRmrUser()) {
            attach('Org Chart', 'wrong-chart');
            submitAndClassify(); // Dealer Application missing, Org Chart wrong type -> Needs Review
            Assert.areEqual(DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_FAILED, pkg().Status__c, 'Issues fail the review');

            String oldToken = [SELECT Upload_Token__c FROM DNAMS_Package__c LIMIT 1].Upload_Token__c;
            DNAMS_RmrReviewService.sentHistoryStub = false;
            String neverSent = sendReturnViaFlow(pkg().Id);
            Assert.isTrue(neverSent.contains('cannot be returned'), neverSent);

            DNAMS_RmrReviewService.sentHistoryStub = true;
            update new DNAMS_Package__c(Id = pkg().Id, Upload_Link_Sent_To__c = null);
            String noEmail = sendReturnViaFlow(pkg().Id);
            Assert.isTrue(noEmail.contains(DNAMS_RmrReviewService.MISSING_EMAIL), noEmail);

            update new DNAMS_Package__c(Id = pkg().Id, Upload_Link_Sent_To__c = 'principal@example.com');
            DNAMS_ReviewActionCheck.Result check = checkViaFlow(pkg().Id, 'SendReturn');
            Assert.isTrue(check.canProceed && check.message.contains('Return package'), check.message);
            String message = sendReturnViaFlow(pkg().Id);

            Assert.isTrue(message.contains('was returned'), message);
            DNAMS_Package__c returned = [SELECT Status__c, Upload_Link_Sent_At__c FROM DNAMS_Package__c WHERE Id = :pkg().Id];
            Assert.areEqual('Returned', returned.Status__c, 'Package is Returned');
            Assert.isNotNull(returned.Upload_Link_Sent_At__c, 'The send is stamped');

            // The dealer page shows each stuck element's narrative after the return.
            String token = [SELECT Upload_Token__c FROM DNAMS_Package__c LIMIT 1].Upload_Token__c;
            Assert.areEqual(64, token.length(), 'Return sends a new 64-hex token');
            Assert.isFalse(token.equals(oldToken), 'Return replaces the upload link');
            try {
                DNAMS_GuestUploadController.getPackage(oldToken);
                Assert.fail('The old link must stop working');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('not valid'), e.getMessage());
            }
            DNAMS_GuestUploadController.PackageView view = DNAMS_GuestUploadController.getPackage(token);
            Assert.isFalse(view.isClosed, 'A returned package is open again');
            Assert.isTrue(view.elements[1].issue.contains('Found Bank Statement instead of Org Chart'), view.elements[1].issue);
        }
    }

    /**
     * @description Draft: a missing email blocks the send; with an email the link is sent and the package becomes Initiated.
     * Initiated: the check offers a resend, which keeps the status.
     **/
    @IsTest
    static void sendFromDraftThenOfferResend() {
        Id packageId = pkg().Id;
        System.runAs(createRmrUser()) {
            update new DNAMS_Package__c(Id = packageId, Status__c = 'Draft', Upload_Link_Sent_To__c = null);
            DNAMS_ReviewActionCheck.Result noEmail = checkViaFlow(packageId, 'SendReturn');
            Assert.isFalse(noEmail.canProceed, 'A missing email blocks the send');
            Assert.areEqual(DNAMS_RmrReviewService.MISSING_EMAIL, noEmail.message, 'The missing email is explained');

            update new DNAMS_Package__c(Id = packageId, Upload_Link_Sent_To__c = 'principal@example.com');
            DNAMS_ReviewActionCheck.Result ready = checkViaFlow(packageId, 'SendReturn');
            Assert.isTrue(ready.canProceed && ready.message.contains('Send the upload link'), ready.message);

            String sent = sendReturnViaFlow(packageId);
            Assert.isTrue(sent.contains('is now Initiated'), sent);
            DNAMS_Package__c initiated = [SELECT Status__c, Upload_Link_Sent_At__c FROM DNAMS_Package__c WHERE Id = :packageId];
            Assert.areEqual('Initiated', initiated.Status__c, 'Sending moves the package to Initiated');
            Assert.isNotNull(initiated.Upload_Link_Sent_At__c, 'The send is stamped');

            DNAMS_ReviewActionCheck.Result resend = checkViaFlow(packageId, 'SendReturn');
            Assert.isTrue(resend.canProceed && resend.message.contains('resend it anyway'), resend.message);
            String again = sendReturnViaFlow(packageId);
            Assert.isTrue(again.contains('emailed again'), again);
            Assert.areEqual('Initiated', pkg().Status__c, 'A resend keeps the status');
        }
    }

    /**
     * @description A user without DNAMS_RMR cannot use the RMR actions.
     **/
    @IsTest
    static void nonRmrUserIsBlocked() {
        User plain = new User(
            Alias = 'dnamsx',
            Email = 'dnams.plain@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Plain',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User'].Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'dnams.plain.' + System.currentTimeMillis() + '@example.com'
        );
        insert plain;
        Id packageId = pkg().Id;
        System.runAs(plain) {
            String message = cancelViaFlow(packageId);
            Assert.isTrue(message.contains('Only RMR'), message);
        }
    }

    // ------------------------------------------------------------------ 18-20 narrative

    /**
     * @description The narrative is written to the package and an RMR owner is emailed.
     **/
    @IsTest
    static void narrativeIsWrittenAndRmrEmailed() {
        useStubs();
        User rmrUser = createRmrUser();
        System.runAs(rmrUser) {
            update new DNAMS_Package__c(Id = pkg().Id, OwnerId = rmrUser.Id);
            AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(Package__c = pkg().Id, Status__c = 'Completed', Issue_Summary__c = '- Org Chart [Failed]: wrong type.');
            insert run;

            new DNAMS_PackageNarrativeQueueable(run.Id).execute(null);

            DNAMS_Package__c saved = [SELECT AI_Narrative__c, AI_Narrative_JSON__c, Health__c FROM DNAMS_Package__c WHERE Id = :pkg().Id];
            Assert.isTrue(saved.AI_Narrative__c.contains('bank statement'), saved.AI_Narrative__c);
            Map<String, Object> summary = (Map<String, Object>) JSON.deserializeUntyped(saved.AI_Narrative_JSON__c);
            Assert.areEqual('One element needs a new document', summary.get('headline'), 'Headline kept');
            Assert.areNotEqual('GREEN', summary.get('overall_health'), 'Health comes from the package, not the model');
            Map<String, Object> element = (Map<String, Object>) ((List<Object>) summary.get('elements'))[0];
            Assert.areEqual('FAILED', element.get('status'), 'Status normalised');
            Assert.isNotNull([SELECT Narrative_Input__c FROM AI_Package_Review_Run__c WHERE Id = :run.Id].Narrative_Input__c, 'Facts kept for audit');
            String reason = reload(run.Id).Reason__c;
            Assert.isTrue(reason.contains('emailed the package owner'), reason);
        }
    }

    /**
     * @description A model failure falls back to the issue summary; a queue owner is recorded, not emailed.
     **/
    @IsTest
    static void narrativeFallsBackWhenModelFails() {
        StubWriter writer = useStubs();
        writer.fail = true;
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            update new DNAMS_Package__c(Id = pkg().Id, OwnerId = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'CENTRAL_RMR'].Id);
            AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(Package__c = pkg().Id, Status__c = 'Completed', Issue_Summary__c = '- Org Chart [Failed]: missing.');
            insert run;

            new DNAMS_PackageNarrativeQueueable(run.Id).execute(null);

            String narrative = pkg().AI_Narrative__c;
            Assert.isTrue(narrative.contains('missing'), narrative);
            Assert.isNotNull([SELECT AI_Narrative_JSON__c FROM DNAMS_Package__c WHERE Id = :pkg().Id].AI_Narrative_JSON__c, 'The rule-based summary has the same structure');
            AI_Package_Review_Run__c after = reload(run.Id);
            Assert.isTrue(after.Error__c.contains('fell back'), after.Error__c);
            Assert.isTrue(after.Reason__c.contains('RMR not emailed'), 'Queue/non-RMR owner is recorded only');
        }
    }
}
