export type Row = Record<string, any>;
export type WorkshopData = {jobs:Row[];vehicles:Row[];customers:Row[];products:Row[];inventory:Row[];technicians:Row[];pdi:Row[];templates:Row[];warranties:Row[];claims:Row[];deliveries:Row[];invoices:Row[];payments:Row[];events:Row[]};
export const emptyWorkshop:WorkshopData={jobs:[],vehicles:[],customers:[],products:[],inventory:[],technicians:[],pdi:[],templates:[],warranties:[],claims:[],deliveries:[],invoices:[],payments:[],events:[]};
export const jobStatuses=['new','assigned','vehicle_received','inspection','work_in_progress','waiting_for_parts','ready_for_delivery','invoiced','paid','completed'];
export const serviceTypes=['General Service','Periodic Service','Breakdown','Engine Repair','Hydraulic','Electrical','Brake','Battery','Tyre','Warranty','Other'];
export const label=(s:string)=>s.replaceAll('_',' ').replace(/\b\w/g,c=>c.toUpperCase());
export const today=()=>new Date().toLocaleDateString('en-CA');
export const warrantyStatus=(w:Row)=>{const now=new Date();const end=new Date(w.end_date+'T23:59:59');return new Date(w.start_date)>now?'Not started':end<now?'Expired':end.getTime()-now.getTime()<30*86400000?'Expiring soon':'Active'};
