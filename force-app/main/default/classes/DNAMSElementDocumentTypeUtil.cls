/**
 * @description     Reads mapping 1 (DNAMSElementDocumentType__mdt: element type -> accepted document types -> identifying
 *                  instructions) for the classification stage: the prompt text per element and the accepted names Apex
 *                  checks the classifier's answer against.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
public inherited sharing class DNAMSElementDocumentTypeUtil {
    // Tests inject rows here so they never depend on the deployed CMDT records.
    @TestVisible
    private static List<DNAMSElementDocumentType__mdt> rowsOverride;

    /**
     * @description Returns the active mapping rows grouped by element type. SOQL (not getAll) because getAll truncates
     *              long text area fields such as IdentifyingInstructions__c to 255 characters.
     * @return      Active rows keyed by ElementType__c in lower case, each list ordered by SortOrder__c
     **/
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static Map<String, List<DNAMSElementDocumentType__mdt>> getByElementType() {
        // PMD.ApexCRUDViolation suppressed: CMDT is pipeline configuration, not user data, so it is read in system mode.
        List<DNAMSElementDocumentType__mdt> rows = rowsOverride ?? [
            SELECT ElementType__c, DocumentType__c, IdentifyingInstructions__c, SortOrder__c, IsActive__c
            FROM DNAMSElementDocumentType__mdt
            WHERE IsActive__c = TRUE
            ORDER BY ElementType__c, SortOrder__c
        ];
        Map<String, List<DNAMSElementDocumentType__mdt>> rowsByType = new Map<String, List<DNAMSElementDocumentType__mdt>>();
        for (DNAMSElementDocumentType__mdt row : rows) {
            if (!row.IsActive__c || String.isBlank(row.ElementType__c) || String.isBlank(row.DocumentType__c)) {
                continue;
            }
            String key = row.ElementType__c.trim().toLowerCase();
            if (!rowsByType.containsKey(key)) {
                rowsByType.put(key, new List<DNAMSElementDocumentType__mdt>());
            }
            rowsByType.get(key).add(row);
        }
        return rowsByType;
    }

    /**
     * @description Builds the AcceptedDocumentTypes__c prompt input: one line per row, "- <DocumentType>: <instructions>",
     *              with the instructions collapsed onto one line.
     * @param rows  Mapping rows of one element type, in prompt order
     * @return      The prompt lines joined by new lines, or null when there are no rows
     **/
    public static String buildPromptText(List<DNAMSElementDocumentType__mdt> rows) {
        if (rows == null || rows.isEmpty()) {
            return null;
        }
        List<String> lines = new List<String>();
        for (DNAMSElementDocumentType__mdt row : rows) {
            String instructions = row.IdentifyingInstructions__c?.normalizeSpace();
            lines.add('- ' + row.DocumentType__c.trim() + (String.isBlank(instructions) ? '' : ': ' + instructions));
        }
        return String.join(lines, '\n');
    }

    /**
     * @description Returns the document type names an element accepts, for the deterministic check of the AI answer.
     * @param rows  Mapping rows of one element type
     * @return      DocumentType__c values in lower case (empty when there are no rows)
     **/
    public static Set<String> getAcceptedNames(List<DNAMSElementDocumentType__mdt> rows) {
        Set<String> names = new Set<String>();
        for (DNAMSElementDocumentType__mdt row : rows ?? new List<DNAMSElementDocumentType__mdt>()) {
            names.add(row.DocumentType__c.trim().toLowerCase());
        }
        return names;
    }
}
