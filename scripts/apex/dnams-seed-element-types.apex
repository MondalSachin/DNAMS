// Seeds the 22 DNAMS element types (shared by every package) with their order and required flag.
// Safe to re-run: element types are matched by Name.
// After seeding, admins maintain them from the Element Types tab.
// Run: sf apex run -o dnams -f scripts/apex/dnams-seed-element-types.apex

String sign = 'Signature';
// { element type name, instructions, required, identifying definition (used by the classification prompt) }
List<List<Object>> rows = new List<List<Object>>{
    new List<Object>{ 'DSSA or Amendment', sign, false, 'Dealer Sales and Service Agreement (DSSA) between the manufacturer and the dealer, or an amendment to it: a legal agreement with numbered articles, named parties, term and signature blocks.' },
    new List<Object>{ 'DSSA Addendums - OMA', sign, false, 'An addendum to the DSSA identified as the OMA addendum (title or header mentions OMA), referencing the DSSA, with signature blocks.' },
    new List<Object>{ 'DSSA Addendums - ROFR', sign, false, 'An addendum to the DSSA granting the manufacturer a Right of First Refusal (ROFR) on a sale or transfer of the dealership, with signature blocks.' },
    new List<Object>{ 'DSSA Addendums - Facilities', sign, false, 'An addendum to the DSSA covering the dealership facility: location, building, square footage or facility commitments, with signature blocks.' },
    new List<Object>{ 'S2 Conditional Approval Letter', null, false, 'A letter from the manufacturer giving conditional (S2) approval to the dealer or applicant and listing the conditions still to be met.' },
    new List<Object>{ 'Dealer Application', 'All fields are completed including SSN and DOB.', true, 'An application form completed by the dealer or dealer principal with personal and business details (name, address, ownership, SSN and date of birth fields) and signatures.' },
    new List<Object>{ 'Electronic Photograph of Dealer Principal', 'Attach image file (jpeg or png); Image should be of the head and shoulders on a neutral background.', false, 'A head-and-shoulders portrait photograph of a single person, typically on a plain or neutral background.' },
    new List<Object>{ 'Financial Facility Signage Standards', 'All fields to be completed (specify your individual Planning Guide); include Actual Square Footages for each department of your facility; sign the document.', false, 'A facility and signage standards form listing departments with actual square footages, referencing a planning guide, and signed by the dealer.' },
    new List<Object>{ 'Address Verification', 'Upload both the completed Address Verification Form (all address and contact information fields filled in) and a recent Utility Bill issued to the dealership at the dealership address.', true, 'A form or document confirming the dealership business address and contact information (street address, city, state, postal code, phone, email).' },
    new List<Object>{ 'Photographs of Facility', 'Include in the PowerPoint presentation, a comprehensive set of photographs of all departments of the dealership (including signage).', true, 'Photographs, or a presentation of photographs, of the dealership premises: building exterior, showroom, service and parts areas, and signage.' },
    new List<Object>{ 'Bank Flooring Letter', 'Attach copy of flooring letter from your financial institution; if not yet available attach conditional approval letter.', false, 'A letter from a bank or financial institution confirming a floor plan (flooring) credit line for vehicle inventory, or a conditional approval of one, usually stating a credit limit.' },
    new List<Object>{ 'Flooring Worksheet', 'Complete flooring source and actual limit sections.', false, 'A worksheet listing the flooring (floor plan) sources and the actual credit limits, typically by vehicle category.' },
    new List<Object>{ 'NWC Improvement Plan', 'Complete and attach a comprehensive Improvement Plan to meet your minimum NWC requirement (if applicable).', false, 'A plan describing how the dealership will meet its minimum Net Working Capital (NWC) requirement, with financial figures, actions and a timeline.' },
    new List<Object>{ 'Deed Lease Agreement', 'Attach a copy of the current lease for the facility/location.', false, 'A property deed or a lease agreement for the dealership premises naming landlord and tenant (or grantor and grantee), the premises, the term and the rent.' },
    new List<Object>{ 'Articles of Incorporation or Organization', 'Attach a copy of the filed Articles of Incorporation or Organization for your dealership entity, as well as any corporate owners/holding companies.', false, 'A state-filed formation document for a corporation (Articles of Incorporation) or LLC (Articles of Organization): entity name, registered agent, filing stamp or date.' },
    new List<Object>{ 'ByLaws / Operating Agreement / Partnership Agreement', 'Attach a copy of the dealership entity Bylaws or Operating Agreement, as well as any corporate owners/holding companies.', false, 'The internal governing agreement of the dealership entity: corporate bylaws, an LLC operating agreement, or a partnership agreement.' },
    new List<Object>{ 'Corporate Resolution(s)', 'Complete, sign, and upload all pertinent Resolutions.', false, 'A resolution of the board of directors or members, typically with "RESOLVED that" clauses, adopted and signed or certified by an officer.' },
    new List<Object>{ 'Certificate of Secretary/Partnership/Manager', 'Complete, sign, and upload the Certificates for your dealership entity, as well as any corporate owners/holding companies.', false, 'A certificate signed by the secretary, a partner or the manager certifying officers, incumbency, authority or resolutions of the entity.' },
    new List<Object>{ 'Stock_Membership Certificate_Copy of Trust', 'Attach a copy of the Stock / Membership Certificates issued for your dealership entity, as well as any corporate owners/holding companies; attach copy of Trust Agreement (if applicable).', false, 'A stock certificate or LLC membership certificate showing shares or units owned by a named holder, or a copy of a trust agreement.' },
    new List<Object>{ 'Org Chart', 'Attach Organizational Chart identifying all levels of dealership ownership (all owners).', true, 'A diagram of the ownership structure of the dealership showing owners, holding companies and ownership percentages at every level.' },
    new List<Object>{ 'Dealer Information Sharing Agreement', null, false, 'An agreement between the dealer and the manufacturer governing how dealer data and information is shared and used, with signatures.' },
    new List<Object>{ 'Miscellaneous Documents', null, false, 'Any other supporting document related to the dealership or this package.' }
};

Map<String, DNAMS_Element_Type__c> typesByName = new Map<String, DNAMS_Element_Type__c>();
for (DNAMS_Element_Type__c existing : [SELECT Id, Name FROM DNAMS_Element_Type__c]) {
    typesByName.put(existing.Name, existing);
}
List<DNAMS_Element_Type__c> types = new List<DNAMS_Element_Type__c>();
for (Integer i = 0; i < rows.size(); i++) {
    List<Object> row = rows[i];
    DNAMS_Element_Type__c elementType = typesByName.get((String) row[0]) ?? new DNAMS_Element_Type__c(Name = (String) row[0]);
    elementType.Instructions__c = (String) row[1];
    elementType.Is_Required__c = (Boolean) row[2];
    elementType.Identifying_Definition__c = (String) row[3];
    elementType.Sort_Order__c = i + 1;
    elementType.Is_Active__c = true;
    types.add(elementType);
}
upsert types;
System.debug('Seeded ' + types.size() + ' element types.');
