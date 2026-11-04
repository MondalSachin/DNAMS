/**
 * @description     Compares an IDP extraction result with the expected structure from the action's schema JSON
 *                  (configuration.content.output.fields and .tables). Keys only; values are not checked.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
public inherited sharing class DNAMSStructureValidationUtil {
    /**
     * @description Result of one structure check.
     **/
    public class ValidationResult {
        public Boolean isValid;
        public List<String> missingKeys;
        public List<String> unexpectedKeys;
    }

    /**
     * @description Validates the output keys. Expected keys: every field, every table, and every column as
     *              'Table.Column'. A key present with a null value counts as present. Columns of a table returned
     *              with zero rows count as present, since an empty table cannot show its columns.
     * @param expectedStructureJson Full schema JSON (DNAMSIDPAction__mdt.ExpectedStructure__c)
     * @param output                Normalized extraction result
     * @return                      Sorted missing (expected - actual) and unexpected (actual - expected) keys
     * @throws DNAMSPipelineException when the schema has no configuration.content.output node
     **/
    public static ValidationResult validate(String expectedStructureJson, DNAMSIDPWrapper.NormalizedOutput output) {
        Set<String> expectedKeys = getExpectedKeys(expectedStructureJson);
        Set<String> actualKeys = getActualKeys(output);
        for (String tableName : output.tables.keySet()) {
            if (output.tables.get(tableName).isEmpty()) {
                addColumnsOfTable(actualKeys, expectedKeys, tableName);
            }
        }
        ValidationResult result = new ValidationResult();
        result.missingKeys = subtract(expectedKeys, actualKeys);
        result.unexpectedKeys = subtract(actualKeys, expectedKeys);
        result.isValid = result.missingKeys.isEmpty() && result.unexpectedKeys.isEmpty();
        return result;
    }

    /**
     * @description Expected keys from the schema JSON.
     * @param expectedStructureJson Schema JSON
     * @return                      Field, table and Table.Column keys
     **/
    private static Set<String> getExpectedKeys(String expectedStructureJson) {
        Map<String, Object> outputNode = null;
        if (String.isNotBlank(expectedStructureJson)) {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(expectedStructureJson);
            Map<String, Object> configuration = (Map<String, Object>) root.get('configuration');
            Map<String, Object> content = (Map<String, Object>) configuration?.get('content');
            outputNode = (Map<String, Object>) content?.get('output');
        }
        if (outputNode == null) {
            throw new DNAMSPipelineException('Expected structure has no configuration.content.output node.');
        }
        Map<String, Object> fields = (Map<String, Object>) outputNode.get('fields') ?? new Map<String, Object>();
        Map<String, Object> tables = (Map<String, Object>) outputNode.get('tables') ?? new Map<String, Object>();
        Set<String> keys = new Set<String>(fields.keySet());
        for (String tableName : tables.keySet()) {
            keys.add(tableName);
            Map<String, Object> columns = (Map<String, Object>) tables.get(tableName) ?? new Map<String, Object>();
            for (String column : columns.keySet()) {
                keys.add(tableName + '.' + column);
            }
        }
        return keys;
    }

    /**
     * @description Actual keys from the normalized output.
     * @param output Normalized output
     * @return       Field, table and Table.Column keys
     **/
    private static Set<String> getActualKeys(DNAMSIDPWrapper.NormalizedOutput output) {
        Set<String> keys = new Set<String>(output.fields.keySet());
        for (String tableName : output.tables.keySet()) {
            keys.add(tableName);
            for (Map<String, Object> row : output.tables.get(tableName)) {
                for (String column : row.keySet()) {
                    keys.add(tableName + '.' + column);
                }
            }
        }
        return keys;
    }

    /**
     * @description Adds the expected 'Table.Column' keys of one table to the actual keys.
     * @param actualKeys   Actual keys (modified)
     * @param expectedKeys Expected keys
     * @param tableName    Table returned with zero rows
     **/
    private static void addColumnsOfTable(Set<String> actualKeys, Set<String> expectedKeys, String tableName) {
        for (String key : expectedKeys) {
            if (key.startsWith(tableName + '.')) {
                actualKeys.add(key);
            }
        }
    }

    /**
     * @description Sorted set difference.
     * @param source Keys to keep
     * @param remove Keys to drop
     * @return       Sorted source - remove
     **/
    private static List<String> subtract(Set<String> source, Set<String> remove) {
        Set<String> difference = new Set<String>(source);
        difference.removeAll(remove);
        List<String> sorted = new List<String>(difference);
        sorted.sort();
        return sorted;
    }
}
