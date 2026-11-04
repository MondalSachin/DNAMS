/**
 * @description     Request/response wrappers for the MuleSoft IDP integration and the parser that turns any IDP
 *                  result shape (pages envelope, flat envelope, value-only stub JSON) into one NormalizedOutput.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
public inherited sharing class DNAMSIDPWrapper {
    private static final String KEY_PAGES = 'pages';
    private static final String KEY_FIELDS = 'fields';
    private static final String KEY_TABLES = 'tables';
    private static final String KEY_VALUE = 'value';

    /**
     * @description One DNAMSIDPAction__mdt record (document type to IDP action mapping).
     **/
    public class ActionConfig {
        public String developerName;
        public String documentType;
        public String actionId;
        public String actionVersion;
        public String postPath;
        public String getPath;
        public String expectedStructure;
        public String stubResource;
    }

    /**
     * @description Input for IDocumentExtractionClient.submitDocument.
     **/
    public class SubmitRequest {
        public ActionConfig action;
        public String fileName;
        public Blob fileBody;
        public String callbackUrl;
    }

    /**
     * @description Outcome of the IDP POST.
     **/
    public class SubmitResult {
        public Boolean isSuccess;
        public Integer statusCode;
        public String executionId;
        public String executionStatus;
        public String responseBody;
        public String errorMessage;
    }

    /**
     * @description Outcome of the IDP GET. isSuccess means HTTP 2xx and a parseable JSON body.
     **/
    public class ExecutionResult {
        public Boolean isSuccess;
        public Integer statusCode;
        public String executionStatus;
        public String responseBody;
        public String errorMessage;
    }

    /**
     * @description Extraction result flattened to plain values: field name to value, table name to rows.
     **/
    public class NormalizedOutput {
        public Map<String, Object> fields = new Map<String, Object>();
        public Map<String, List<Map<String, Object>>> tables = new Map<String, List<Map<String, Object>>>();

        /**
         * @description Fields and tables merged into one map (input for the consolidated extraction JSON).
         * @return      Field values and table rows keyed by name
         **/
        public Map<String, Object> toMap() {
            Map<String, Object> merged = new Map<String, Object>(fields);
            for (String tableName : tables.keySet()) {
                merged.put(tableName, tables.get(tableName));
            }
            return merged;
        }
    }

    /**
     * @description Parses an IDP GET body (or a value-only stub body) into a NormalizedOutput. Pages are merged:
     *              the first non-null value wins per field and table rows are concatenated.
     * @param responseBody Raw JSON body
     * @return             Normalized output; empty when the body is blank
     * @throws JSONException or TypeException when the body is not a JSON object
     **/
    public static NormalizedOutput normalizeOutput(String responseBody) {
        NormalizedOutput output = new NormalizedOutput();
        if (String.isBlank(responseBody)) {
            return output;
        }
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        if (root.get(KEY_PAGES) instanceof List<Object>) {
            for (Object page : (List<Object>) root.get(KEY_PAGES)) {
                mergeSection(output, (Map<String, Object>) page);
            }
        } else if (root.containsKey(KEY_FIELDS) || root.containsKey(KEY_TABLES)) {
            mergeSection(output, root);
        } else {
            mergeValueOnly(output, root);
        }
        return output;
    }

    /**
     * @description Merges one envelope section ({fields, tables}) into the output.
     * @param output  Output being built
     * @param section Page or flat envelope map
     **/
    private static void mergeSection(NormalizedOutput output, Map<String, Object> section) {
        if (section == null) {
            return;
        }
        Map<String, Object> fieldMap = (Map<String, Object>) section.get(KEY_FIELDS);
        for (String fieldName : fieldMap?.keySet() ?? new Set<String>()) {
            mergeField(output, fieldName, fieldMap.get(fieldName));
        }
        Map<String, Object> tableMap = (Map<String, Object>) section.get(KEY_TABLES);
        for (String tableName : tableMap?.keySet() ?? new Set<String>()) {
            mergeTable(output, tableName, (List<Object>) tableMap.get(tableName));
        }
    }

    /**
     * @description Value-only JSON: arrays are tables, everything else is a field.
     * @param output Output being built
     * @param root   Top-level JSON map
     **/
    private static void mergeValueOnly(NormalizedOutput output, Map<String, Object> root) {
        for (String key : root.keySet()) {
            Object value = root.get(key);
            if (value instanceof List<Object>) {
                mergeTable(output, key, (List<Object>) value);
            } else {
                mergeField(output, key, value);
            }
        }
    }

    /**
     * @description Keeps the first non-null value of a field; a null value still marks the key as present.
     * @param output    Output being built
     * @param fieldName Field name
     * @param rawValue  Raw or {value: ..} wrapped value
     **/
    private static void mergeField(NormalizedOutput output, String fieldName, Object rawValue) {
        if (output.fields.get(fieldName) == null) {
            output.fields.put(fieldName, unwrap(rawValue));
        }
    }

    /**
     * @description Appends table rows, unwrapping every cell.
     * @param output    Output being built
     * @param tableName Table name
     * @param rows      Raw rows (may be null)
     **/
    private static void mergeTable(NormalizedOutput output, String tableName, List<Object> rows) {
        if (!output.tables.containsKey(tableName)) {
            output.tables.put(tableName, new List<Map<String, Object>>());
        }
        for (Object row : rows ?? new List<Object>()) {
            Map<String, Object> rawRow = (Map<String, Object>) row;
            Map<String, Object> cleanRow = new Map<String, Object>();
            for (String column : rawRow.keySet()) {
                cleanRow.put(column, unwrap(rawRow.get(column)));
            }
            output.tables.get(tableName).add(cleanRow);
        }
    }

    /**
     * @description Returns .value of a {value, confidenceScore, ...} object, otherwise the value itself.
     * @param rawValue Raw value
     * @return         Plain value
     **/
    private static Object unwrap(Object rawValue) {
        if (rawValue instanceof Map<String, Object> && ((Map<String, Object>) rawValue).containsKey(KEY_VALUE)) {
            return ((Map<String, Object>) rawValue).get(KEY_VALUE);
        }
        return rawValue;
    }
}
