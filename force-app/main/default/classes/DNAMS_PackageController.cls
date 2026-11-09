/**
 * Backs dnamsPackageSender on the DNAMS Dealer Portal home page (logged-in users only; the site guest
 * profile has no access to this class): lists packages not yet submitted and emails their upload link.
 */
public with sharing class DNAMS_PackageController {
    public static final String SITE_NAME = 'DNAMS Dealer Portal';

    @AuraEnabled
    public static List<PackageRow> getUnsubmittedPackages() {
        List<PackageRow> rows = new List<PackageRow>();
        for (DNAMS_Package__c pkg : [
            SELECT
                Id,
                Name,
                Package_Name__c,
                Demo_Scenario__c,
                Type__c,
                Status__c,
                Upload_Token__c,
                Buying_Dealer__r.Name,
                Primary_Contact__r.Name,
                Primary_Contact__r.Email,
                Upload_Link_Sent_To__c,
                Upload_Link_Sent_At__c
            FROM DNAMS_Package__c
            WHERE Status__c IN :DNAMS_PackageService.EDITABLE_STATUSES
            WITH USER_MODE
            ORDER BY Name
            LIMIT 200
        ]) {
            rows.add(new PackageRow(pkg, uploadLink(pkg.Upload_Token__c)));
        }
        return rows;
    }

    @AuraEnabled
    public static void sendUploadLink(Id packageId, String recipientEmail) {
        DNAMS_Package__c pkg = [
            SELECT Id, Name, Package_Name__c, Status__c, Upload_Token__c, Buying_Dealer__r.Name
            FROM DNAMS_Package__c
            WHERE Id = :packageId
            WITH USER_MODE
        ];
        if (!DNAMS_PackageService.EDITABLE_STATUSES.contains(pkg.Status__c)) {
            throw error('Package ' + pkg.Name + ' is already submitted.');
        }

        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setToAddresses(new List<String>{ recipientEmail });
        message.setSubject('Harbor Motors: upload documents for package ' + pkg.Name);
        message.setPlainTextBody(
            'Hello,\n\n' +
                'Please upload the documents for package ' + pkg.Name + ' (' + pkg.Package_Name__c + ')' +
                (pkg.Buying_Dealer__r == null ? '' : ' for ' + pkg.Buying_Dealer__r.Name) + '.\n\n' +
                'Open this link, upload a document for each required element and click Submit Package:\n' +
                uploadLink(pkg.Upload_Token__c) + '\n\n' +
                'The link is personal to this package. Please do not forward it.\n\n' +
                'Thank you,\nHarbor Motors Dealer Network'
        );
        message.setSaveAsActivity(false);
        DNAMSEmailSender.applySender(message);
        try {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });
        } catch (EmailException e) {
            throw error('The email could not be sent: ' + e.getMessage());
        }

        Database.update(
            new DNAMS_Package__c(Id = pkg.Id, Upload_Link_Sent_To__c = recipientEmail, Upload_Link_Sent_At__c = System.now()),
            AccessLevel.USER_MODE
        );
    }

    /** https://<site domain>/<site prefix>/?token=<upload token> */
    public static String uploadLink(String token) {
        List<Network> sites = [SELECT Id FROM Network WHERE Name = :SITE_NAME LIMIT 1];
        String baseUrl = sites.isEmpty() ? '' : Network.getLoginUrl(sites[0].Id)?.removeEnd('/login');
        return baseUrl + '/?token=' + token;
    }

    private static AuraHandledException error(String message) {
        // setMessage keeps the real message for Apex callers and logs, not only for the LWC.
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    public class PackageRow {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String packageNumber;
        @AuraEnabled
        public String packageName;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String dealerName;
        @AuraEnabled
        public String primaryContactName;
        @AuraEnabled
        public String primaryContactEmail;
        @AuraEnabled
        public String lastSentTo;
        @AuraEnabled
        public Datetime lastSentAt;
        @AuraEnabled
        public String uploadLink;
        @AuraEnabled
        public String demoScenario;

        PackageRow(DNAMS_Package__c pkg, String uploadLink) {
            this.id = pkg.Id;
            this.packageNumber = pkg.Name;
            this.demoScenario = pkg.Demo_Scenario__c;
            this.packageName = pkg.Package_Name__c;
            this.status = pkg.Status__c;
            this.dealerName = pkg.Buying_Dealer__r?.Name;
            this.primaryContactName = pkg.Primary_Contact__r?.Name;
            this.primaryContactEmail = pkg.Primary_Contact__r?.Email;
            this.lastSentTo = pkg.Upload_Link_Sent_To__c;
            this.lastSentAt = pkg.Upload_Link_Sent_At__c;
            this.uploadLink = uploadLink;
        }
    }
}