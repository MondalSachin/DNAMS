/**
 * @description     Unit tests for DNAMSIDPWrapper.normalizeOutput and NormalizedOutput.toMap.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
@IsTest
private class DNAMSIDPWrapperTest {
    /**
     * @description Pages envelope: first non-null field wins across pages; table rows concatenate.
     **/
    @IsTest
    static void testNormalizeOutputPagesMergesFieldsAndTables() {
        String body = '{"id":"e1","status":"SUCCEEDED","pages":['
            + '{"page":1,"fields":{"DealerCode":null,"Landlord":{"value":"Morse"}},"tables":{"AddressTable":[{"Status":{"value":"Confirmed"}}]}},'
            + '{"page":2,"fields":{"DealerCode":{"value":"40718"},"Landlord":{"value":"Other"}},"tables":{"AddressTable":[{"Status":{"value":"Corrected"}}]}}'
            + ']}';
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            DNAMSIDPWrapper.NormalizedOutput output = DNAMSIDPWrapper.normalizeOutput(body);
            Test.stopTest();
            Assert.areEqual('40718', output.fields.get('DealerCode'), 'Null on page 1 is replaced by page 2 value');
            Assert.areEqual('Morse', output.fields.get('Landlord'), 'First non-null value wins');
            Assert.areEqual(2, output.tables.get('AddressTable').size(), 'Rows from both pages are concatenated');
            Assert.areEqual('Corrected', output.tables.get('AddressTable')[1].get('Status'), 'Cells are unwrapped');
        }
    }

    /**
     * @description Flat envelope with valueOnly=false objects keeps only .value; null fields stay present.
     **/
    @IsTest
    static void testNormalizeOutputFlatEnvelopeWithConfidence() {
        String body = '{"id":"e1","status":"SUCCEEDED",'
            + '"fields":{"TradeName":{"value":"Acme","confidenceScore":0.97,"geometry":{},"pageNumber":1},"Email":null},'
            + '"tables":{"Owners":[{"Name":{"value":"Jo","confidenceScore":0.9}}],"Empty":null}}';
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            DNAMSIDPWrapper.NormalizedOutput output = DNAMSIDPWrapper.normalizeOutput(body);
            Test.stopTest();
            Assert.areEqual('Acme', output.fields.get('TradeName'), 'Value is taken from the confidence object');
            Assert.isTrue(output.fields.containsKey('Email'), 'Null field is kept as present');
            Assert.areEqual('Jo', output.tables.get('Owners')[0].get('Name'), 'Table cell value is unwrapped');
            Assert.isTrue(output.tables.get('Empty').isEmpty(), 'Null table becomes an empty row list');
            Assert.isFalse(output.fields.containsKey('status'), 'Envelope keys are not treated as fields');
        }
    }

    /**
     * @description Value-only stub JSON: arrays are tables, other keys are fields; toMap merges both.
     **/
    @IsTest
    static void testNormalizeOutputValueOnlyAndToMap() {
        String body = '{"DealerCode":"40718","Landlord":null,"AddressTable":[{"Status":"Confirmed","AddressType":"Mailing"}]}';
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            DNAMSIDPWrapper.NormalizedOutput output = DNAMSIDPWrapper.normalizeOutput(body);
            Map<String, Object> merged = output.toMap();
            Test.stopTest();
            Assert.areEqual(2, output.fields.size(), 'Two scalar keys become fields');
            Assert.areEqual('Mailing', output.tables.get('AddressTable')[0].get('AddressType'), 'Array becomes a table');
            Assert.areEqual(3, merged.size(), 'toMap holds fields and tables');
            Assert.isTrue(merged.get('AddressTable') instanceof List<Map<String, Object>>, 'Table rows are kept as a list');
        }
    }

    /**
     * @description Blank body gives an empty output.
     **/
    @IsTest
    static void testNormalizeOutputBlankBody() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Test.startTest();
            DNAMSIDPWrapper.NormalizedOutput output = DNAMSIDPWrapper.normalizeOutput('');
            Test.stopTest();
            Assert.isTrue(output.fields.isEmpty() && output.tables.isEmpty(), 'Blank body yields no keys');
        }
    }
}
