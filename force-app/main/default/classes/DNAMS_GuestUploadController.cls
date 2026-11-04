/**
 * Backs dnamsPackageUpload, the public upload page reached from the emailed link (?token=...).
 * The site guest profile has no object permissions; this class is its only way in, so every method
 * is scoped to the single package whose Upload Token matches. Queries and DML use explicit SYSTEM_MODE:
 * for the site guest, "without sharing" alone still returns no rows on this API version.
 * File uploads themselves go through lightning-file-upload and are validated by the ContentVersion trigger.
 * When a package is Returned, the page also shows the AI narrative and each element's issue, and lets the
 * dealer remove wrong files (unlinks them from the element) before resubmitting.
 */
public without sharing class DNAMS_GuestUploadController {
    private static final String NOT_FOUND = 'This upload link is not valid.';

    @AuraEnabled
    public static PackageView getPackage(String token) {
        DNAMS_Package__c pkg = findPackage(token);
        PackageView view = new PackageView();
        view.packageNumber = pkg.Name;
        view.packageName = pkg.Package_Name__c;
        view.packageType = pkg.Type__c;
        view.status = pkg.Status__c;
        view.isEditable = DNAMS_PackageService.EDITABLE_STATUSES.contains(pkg.Status__c);
        view.isReturned = pkg.Status__c == DNAMS_PackageService.STATUS_RETURNED;
        view.narrative = view.isReturned ? pkg.AI_Narrative__c : null;
        view.aiLabel = DNAMS_PackageNarrativeQueueable.AI_LABEL;

        Map<Id, ElementView> elementsById = new Map<Id, ElementView>();
        for (DNAMS_Package_Element__c element : [
            SELECT Id, Name, Is_Required__c, Element_Narrative__c, Element_Type__r.Instructions__c
            FROM DNAMS_Package_Element__c
            WHERE Package__c = :pkg.Id
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC NULLS LAST, Name
        ]) {
            ElementView row = new ElementView();
            row.id = element.Id;
            row.name = element.Name;
            row.isRequired = element.Is_Required__c;
            row.instructions = element.Element_Type__r?.Instructions__c;
            row.issue = view.isReturned ? element.Element_Narrative__c : null;
            elementsById.put(element.Id, row);
        }
        if (!elementsById.isEmpty()) {
            for (ContentDocumentLink link : [
                SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension
                FROM ContentDocumentLink
                WHERE LinkedEntityId IN :elementsById.keySet()
                WITH SYSTEM_MODE
                ORDER BY ContentDocument.CreatedDate
            ]) {
                // Names and ids only (the id is used to remove the file); guests have no download access.
                String extension = link.ContentDocument.FileExtension;
                DocumentView doc = new DocumentView();
                doc.id = link.ContentDocumentId;
                doc.name = link.ContentDocument.Title + (String.isBlank(extension) ? '' : '.' + extension);
                elementsById.get(link.LinkedEntityId).documents.add(doc);
            }
        }
        view.elements = elementsById.values();
        return view;
    }

    @AuraEnabled
    public static void submitPackage(String token) {
        DNAMS_Package__c pkg = findPackage(token);
        if (!DNAMS_PackageService.EDITABLE_STATUSES.contains(pkg.Status__c)) {
            throw error('This package has already been submitted.');
        }
        try {
            Database.update(new DNAMS_Package__c(Id = pkg.Id, Status__c = DNAMS_PackageService.STATUS_DEALER_SUBMITTED), AccessLevel.SYSTEM_MODE);
        } catch (DmlException e) {
            throw error(e.getDmlMessage(0));
        }
    }

    /** Unlinks a file from an element of this package while the package is editable. */
    @AuraEnabled
    public static void removeDocument(String token, Id contentDocumentId) {
        DNAMS_Package__c pkg = findPackage(token);
        if (!DNAMS_PackageService.EDITABLE_STATUSES.contains(pkg.Status__c)) {
            throw error(DNAMS_PackageService.LOCKED_MESSAGE);
        }
        Set<Id> elementIds = new Map<Id, DNAMS_Package_Element__c>(
            [SELECT Id FROM DNAMS_Package_Element__c WHERE Package__c = :pkg.Id WITH SYSTEM_MODE]
        ).keySet();
        List<ContentDocumentLink> links = [
            SELECT Id
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :contentDocumentId AND LinkedEntityId IN :elementIds
            WITH SYSTEM_MODE
        ];
        if (links.isEmpty()) {
            throw error('This file is not part of the package.');
        }
        Database.delete(links, AccessLevel.SYSTEM_MODE);
    }

    private static DNAMS_Package__c findPackage(String token) {
        if (String.isBlank(token) || token.length() != 64) {
            throw error(NOT_FOUND);
        }
        List<DNAMS_Package__c> packages = [
            SELECT Id, Name, Package_Name__c, Type__c, Status__c, AI_Narrative__c, Upload_Token__c
            FROM DNAMS_Package__c
            WHERE Upload_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        // SOQL filters and Apex == are case-insensitive; compare exactly.
        if (packages.isEmpty() || !token.equals(packages[0].Upload_Token__c)) {
            throw error(NOT_FOUND);
        }
        return packages[0];
    }

    private static AuraHandledException error(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    public class PackageView {
        @AuraEnabled
        public String packageNumber;
        @AuraEnabled
        public String packageName;
        @AuraEnabled
        public String packageType;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Boolean isEditable;
        @AuraEnabled
        public Boolean isReturned;
        @AuraEnabled
        public String narrative;
        @AuraEnabled
        public String aiLabel;
        @AuraEnabled
        public List<ElementView> elements;
    }

    public class ElementView {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Boolean isRequired;
        @AuraEnabled
        public String instructions;
        @AuraEnabled
        public String issue;
        @AuraEnabled
        public List<DocumentView> documents = new List<DocumentView>();
    }

    public class DocumentView {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
    }
}