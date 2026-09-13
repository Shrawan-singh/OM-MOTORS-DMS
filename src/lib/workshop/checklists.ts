export const checklistSections: Record<string,Record<string,string[]>> = {
 tractor: {
  Engine:['Engine oil','Coolant','Fuel system','Leakage','Starting','Engine sound'],
  Transmission:['Gear operation','Clutch','Transmission oil'],
  Hydraulic:['Hydraulic oil','Lift operation','Leakage','3-point linkage'],
  PTO:['PTO operation','PTO selector'],
  Electrical:['Battery','Headlights','Indicators','Horn','Instrument panel'],
  Tyres:['Front tyres','Rear tyres','Pressure'],
  Exterior:['Paint','Scratches','Body','Seat','Mirrors'],
  Documents:['Invoice / dispatch documents','Warranty documents','Manual','Tool kit']
 },
 e_rickshaw:{Electrical:['Battery','Charger','Controller','Wiring','Motor'],Mechanical:['Brakes','Steering','Suspension','Tyres'],Body:['Roof','Seats','Body panels','Paint'],Electronics:['Display','Lights','Indicators','Horn']},
 cng_rickshaw:{Engine:['Fuel system','Leakage','Starting','Engine oil'],Mechanical:['Brakes','Steering','Suspension','Tyres'],Body:['Roof','Seats','Body panels','Paint'],Electrical:['Battery','Lights','Indicators','Horn']},
 diesel_rickshaw:{Engine:['Fuel system','Leakage','Starting','Engine oil'],Mechanical:['Brakes','Steering','Suspension','Tyres'],Body:['Roof','Seats','Body panels','Paint'],Electrical:['Battery','Lights','Indicators','Horn']}
};
