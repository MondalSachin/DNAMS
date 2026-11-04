/**
 * @description     Tests the RMR actions (Cancel / Re-run review, Return to Dealer) and the package narrative with its
 *                  RMR notification. RMR actions run as an inserted RMR user (System Administrator + DNAMS_Package_Access
 *                  + DNAMS_RMR), so the result does not depend on the permission sets of whoever runs the tests.
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details PMD clean-up; createRmrUser replaces granting DNAMS_RMR to the running user
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-10-20   Sachin Mondal   Initial version
 * 1.1   2026-11-03   Abhishek Dutta  PMD clean-up; System.runAs with an inserted RMR user
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
         * @param runId          Review run (unused)
         * @return               Narrative text
         **/
        public String write(String promptTemplate, Id runId) {
            if (fail) {
                throw new DNAMS_PackageReviewPipelineService.PipelineException('model down');
            }
            return 'Org Chart: a bank statement was uploaded instead of the ownership chart.';
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
        insert new List<DNAMS_Element_Type__c>{
            new DNAMS_Element_Type__c(Name = 'Dealer Application', Sort_Order__c = 1, Is_Required__c = true),
            new DNAMS_Element_Type__c(Name = 'Org Chart', Sort_Order__c = 2, Is_Required__c = true)
        };
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
        DNAMS_RerunReviewAction.Request request = new DNAMS_RerunReviewAction.Request();
        request.packageId = packageId;
        return DNAMS_RerunReviewAction.run(new List<DNAMS_RerunReviewAction.Request>{ request })[0].message;
    }

    /**
     * @description Calls the Return to Dealer invocable as the flow does.
     * @param packageId Package id
     * @param email     Dealer email address
     * @return Message for the flow screen
     **/
    private static String returnViaFlow(Id packageId, String email) {
        DNAMS_ReturnToDealerAction.Request request = new DNAMS_ReturnToDealerAction.Request();
        request.packageId = packageId;
        request.recipientEmail = email;
        return DNAMS_ReturnToDealerAction.run(new List<DNAMS_ReturnToDealerAction.Request>{ request })[0].message;
    }

    // ------------------------------------------------------------------ 1b cancel / re-run

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
        }
    }

    // ------------------------------------------------------------------ 21 return to dealer

    /**
     * @description Return to Dealer needs an email, sets Returned, records the recipient and shows element issues on the dealer page.
     **/
    @IsTest
    static void returnToDealerSetsReturnedAndEmailsLink() {
        useStubs();
        System.runAs(createRmrUser()) {
            attach('Org Chart', 'wrong-chart');
            submitAndClassify(); // Dealer Application missing, Org Chart wrong type -> Needs Review
            Assert.areEqual('RMR Pending', pkg().Status__c, 'Issues send the package to the RMR');

            String noEmail = returnViaFlow(pkg().Id, '');
            Assert.isTrue(noEmail.contains('Enter the dealer email'), noEmail);
            String message = returnViaFlow(pkg().Id, 'principal@example.com');

            Assert.isTrue(message.contains('was returned'), message);
            DNAMS_Package__c returned = pkg();
            Assert.areEqual('Returned', returned.Status__c, 'Package is Returned');
            Assert.areEqual('principal@example.com', returned.Upload_Link_Sent_To__c, 'Recipient is recorded');
            String again = returnViaFlow(pkg().Id, 'principal@example.com');
            Assert.isTrue(again.contains('Return to Dealer is not available'), again);

            // The dealer page shows each stuck element's narrative after the return.
            String token = [SELECT Upload_Token__c FROM DNAMS_Package__c LIMIT 1].Upload_Token__c;
            DNAMS_GuestUploadController.PackageView view = DNAMS_GuestUploadController.getPackage(token);
            Assert.isTrue(view.elements[1].issue.contains('Found Bank Statement instead of Org Chart'), view.elements[1].issue);
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

            String narrative = pkg().AI_Narrative__c;
            Assert.isTrue(narrative.contains('bank statement'), narrative);
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
            AI_Package_Review_Run__c after = reload(run.Id);
            Assert.isTrue(after.Error__c.contains('fell back'), after.Error__c);
            Assert.isTrue(after.Reason__c.contains('RMR not emailed'), 'Queue/non-RMR owner is recorded only');
        }
    }
}
