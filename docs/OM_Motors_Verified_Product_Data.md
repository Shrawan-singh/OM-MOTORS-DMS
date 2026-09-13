# OM Motors — Verified Product Data Pack

## Research date
**12 September 2026 (India)**

## Purpose
This file is the product-data source pack for the OM Motors dealership web application. It is intended to seed the product catalogue, model comparison, Find Your Vehicle recommendations, quotation workflows, compatibility records, and staff-facing product information.

## Data integrity rules
- **Do not invent missing values.** Use `Not published / not verified` when a manufacturer does not expose a value in the source checked.
- Store a `source_url`, `source_type`, `source_checked_on`, and `verification_status` for every model.
- Manufacturer pages/brochures are preferred over third-party portals.
- Prices are intentionally **not treated as permanent product specifications**. Store OM Motors' own current selling price separately, with an effective date and branch/variant.
- Warranty shown here is manufacturer-published warranty where verified; OM Motors may offer/record additional dealer terms separately.
- Product names/variants can change. Keep old/discontinued models in the database with `status=discontinued` rather than deleting them.
- Where two reputable sources disagree, do not merge them into one value. Store both source claims and mark the field `conflict_requires_dealer_verification`.

---

# 1. NEW HOLLAND TRACTORS

Manufacturer: **New Holland Agriculture / CNH Industrial**
Manufacturer India site: https://agriculture.newholland.com/en/india/

## 1.1 New Holland 3600 TX / 3600 TX Super Heritage Edition

### Naming note
The exact historical name “3600 TX” is still found in market/catalogue records. New Holland's current India site lists **3600 TX Super Heritage Edition** as the active/current product page. The current page shows 2WD and 4WD models.

### Manufacturer-published current 3600 TX Super Heritage Edition highlights
- Highest useful power: **42.5 HP** (manufacturer headline)
- Current listed engine: **FPT 8035.05D.943**
- Engine power on page: **35.1 kW / 47 HP**
- Gearbox options: **8F+2R**, **8F+8R***, **16F+4R (SpeedTech)***
- PTO: **EPTRA PTO**
- Hydraulic lifting capacity: **1800 kg**
- Independent PTO clutch lever
- Straight axle planetary drive
- Paddy-special double metal face sealing (optional)
- Potato/onion track width: **48 in**
- 4WD available with MHD axle (optional)
- Variants: **2WD and 4WD**

### Historical/market specification data found for 3600 TX / Heritage Edition
- Cylinders: **3**
- Displacement: **2931 cc** (third-party specification source)
- Fuel tank: **46 L** (third-party comparison source)
- Transmission: Constant Mesh / available Synchro Shuttle depending variant
- Ground clearance: **445 mm** appears in some variant records; verify against the exact VIN/variant before putting on a customer quotation
- Warranty: **6 years / 6000 hours** is manufacturer/marketing material for this family

### App record guidance
Use separate records for:
- `3600_TX_HERITAGE_2WD`
- `3600_TX_HERITAGE_4WD`
- historical `3600_TX`

### Sources
- Official New Holland product page: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-tx-super-heritage-edition
- New Holland corporate brochure/PDF record: https://www.newhollandtractorindia.com/CorporateBrochurePresentation.pdf
- Third-party current market record: https://www.91tractors.com/tractors/new-holland/3600-tx

Verification: **Manufacturer verified for headline/current variant fields; selected dimensions/capacities require variant-level brochure verification.**

---

## 1.2 New Holland 3600-2 TX

### Manufacturer-published facts
- Engine family: **FPT S8000**
- Engine power: **36.94 kW / 49.5 HP** on the current manufacturer page
- Double clutch with independent PTO lever
- Gearbox: **8F+2R / 12F+3R Creeper***
- Sensomatic24 hydraulic lift with **24 sensing points**
- Lifting capacity: **1700 kg with Assist RAM** (manufacturer headline)
- Lift-O-Matic with height limiter
- DRC valve and isolator valve
- Current page identifies the model as **3600-2 TX**

### Detailed brochure/specification data cross-checked
- Cylinders: **3**
- Displacement: **2931 cc**
- Rated RPM: **2500 RPM**
- Cooling: **Water cooled / liquid cooled**
- Air filter: **Oil bath with pre-cleaner**
- Fuel: **Diesel**
- Transmission: **Fully constant mesh / side shift**
- Gears: **8 Forward + 2 Reverse**; creeper configuration available
- PTO: **46 HP**, 540 RPM / GSPTO (source wording varies by record)
- Fuel tank: **60 L**
- Hydraulics: **1700 kg**, Sensomatic24, ADDC; Cat-II 3-point linkage
- Steering: **Power steering**
- Brakes: **Real oil immersed multi-disc brakes**
- Front tyres: **7.50-16**
- Rear tyres: **14.9-28**
- Overall length: **3450 mm**
- Width: **1815 mm**
- Height: **2375 mm**
- Wheelbase: **2045 mm**
- Ground clearance: **445 mm**
- Weight: **2060 kg**
- Battery: **88 Ah** in brochure/third-party records; some market pages show 100 Ah. Do not hard-code one value for all variants.
- Alternator: **45/55 A depending source/variant**
- Warranty: **6 years / 6000 hours**
- Drive: **2WD** for this exact base 3600-2 TX record

### Known compatible/application references from manufacturer brochure
- Cultivator
- MB plough
- Sugarcane haulage
- Straw reaper
- Rotavator
- Laser leveller

### Sources
- Official New Holland page: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-2-tx
- Brochure/specification PDF: https://s3.ap-southeast-1.amazonaws.com/delen/uploads/3bd6ccf9-e6aa-447f-9372-21819ac46900-New%20Holland%203600-2%20TX%20Brochure.pdf
- TractorGuru detailed record: https://tractorguru.in/tractor/new-holland-3600-2-tx
- TractorKarvan detailed record: https://tractorkarvan.com/tractor/new-holland-3600-2-tx

Verification: **Manufacturer headline verified; detailed dimensions/specs cross-checked against brochure/secondary records.**

---

## 1.3 New Holland 3600-2 TX All Rounder Plus+

### Manufacturer-published facts
- Engine: **FPT S8000**
- Engine power: **49.5 HP**
- Double clutch with independent PTO lever
- Gearboxes: **8F+2R, 12F+3R Creeper*, 12F+3R UG***
- Sensomatic24 hydraulic lift with 24 sensing points
- Lifting capacity: **1700 kg / 2000 kg***
- Lift-O-Matic with height limiter
- DRC valve and isolator valve
- Variants: **2WD and 4WD**

### Cross-checked detailed fields for the common 2WD record
- Cylinders: **3** (some third-party pages incorrectly list 4; retain 3 unless exact variant brochure proves otherwise)
- Displacement: **3070 cc** in third-party current records
- Rated RPM: **2100 RPM**
- Air filter: Oil bath with pre-cleaner
- Cooling: Water cooled
- Gearbox: Fully Constant Mesh / Partial Synchromesh depending configuration
- Forward speed range: **1.87–33.83 km/h** in one current detailed record
- Reverse speed range: **2.71–15.16 km/h**
- PTO: **46 HP**, GSPTO/RPTO*, 540 @ 1800 ERPM
- Fuel tank: **60 L**
- Hydraulics: **1700/2000 kg**, DRC valve and isolator valve
- Tyres: **6.5x16 / 7.5x16 front; 14.9x28 / 16.9x28 rear depending variant**
- Wheelbase: **2040 mm**
- Length: **3465 mm**
- Width: **1815 mm**
- Weight: **~2100 kg** in one current detailed record
- Ground clearance: **445 mm**
- Warranty: **6 years / 6000 hours**

### Sources
- Official New Holland page: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3600-2-tx-all-rounder-plus
- TractorGuru: https://tractorguru.in/tractor/new-holland-3600-2-tx-all-rounder-plus
- TractorGyan: https://tractorgyan.com/tractor/new-holland/3600-2-tx-all-rounder-plus-2wd

Verification: **Manufacturer verified for model headline; detailed field set must remain variant-aware.**

---

## 1.4 New Holland 3630 TX

### Naming note
The historical **3630 TX Plus / 3630 TX Plus+** is now represented by newer current variants on New Holland India's site, notably:
- **3630 TX Super Plus+ 2WD / 4WD**
- **3630 TX Super**
- **3630 TX Special Edition**

Legacy models should remain in the app for historical invoices, old customer vehicles, and parts lookup.

### Current 3630 TX Super Plus+ manufacturer facts
- Engine: **FPT S8000**
- Double clutch with independent PTO lever
- Gearboxes: **12F+3R UG, 12F+3R Creeper*, 8F+2R UG***
- Sensomatic24 with 24 sensing points
- Lift capacity: **2000 kg / 1700 kg***
- Lift-O-Matic with height limiter
- DRC valve and isolator valve
- Current variants: **2WD and 4WD**

### Cross-checked legacy 3630 TX Plus+ detailed data
- Cylinders: **3**
- HP: **55 HP** in the legacy 3630 TX Plus+ record; other newer 3630 TX records may be 50 HP. Never mix these as one model.
- Engine: **FPT S8000**, turbo-charged in the legacy Plus+ source
- Displacement: **2991 cc** appears in third-party records
- Rated RPM: **2300 RPM** in the legacy 55 HP record
- Clutch: Double clutch with independent PTO clutch lever
- Gearbox: Fully constant mesh / partial synchromesh depending configuration
- Gear speeds: **8F+2R / 12F+3R Creeper / 12F+3R UG**
- PTO: **540 RPM & GSPTO / RPTO**
- Fuel tank: **60 L**
- Lifting capacity: **1700/2000 kg**
- Front tyre: **7.50x16**
- Rear tyre: **16.9x28** on one legacy record; 14.9x28 appears in other variants
- Wheelbase: **~2040–2045 mm depending variant/source**
- Ground clearance: **445 mm**
- Weight: **~2080–2180 kg depending exact variant/source**
- Battery: **88 Ah** in legacy records
- Alternator: **55 A** in legacy records
- Warranty: **6 years / 6000 hours**

### Current 3630 TX Special Edition manufacturer highlights
- FPT S8000
- Double clutch with independent PTO lever
- 12F+3R UG / 12F+3R Creeper* / 8F+2R UG*
- Sensomatic24
- 2000 kg / 1700 kg* lift
- Lift-O-Matic height limiter
- DRC valve & isolator valve
- ROPS & fibre canopy
- Clear-lens headlamp with DRL signature light
- LED fender lamp
- 2WD and 4WD

### Sources
- Official 3630 TX Super Plus+: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super-plus
- Official 3630 TX Super: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-super
- Official 3630 TX Special Edition: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3630-tx-special-edition
- Legacy detailed record: https://tractorkarvan.com/index.php/tractor/new-holland-3630-tx-plus
- Legacy 4WD record: https://tractorkarvan.com/tractor/new-holland-3630-tx-plus-4wd

Verification: **Current family verified by manufacturer; legacy detailed records are variant-specific and must not be combined.**

---

## 1.5 New Holland 3230 TX

### Manufacturer-published facts
- Maximum PTO power: **39 HP**
- Maximum torque: **166 Nm**
- Gearbox: **Fully Constant Mesh Side Shift AFD**
- DRC valve with Lift-O-Matic
- Multi-speed and Reverse PTO
- SOFTEK clutch
- Neutral safety switch
- Real OIB / oil-immersed braking system
- Clutch safety lock
- Engine: **T-IIIA, S 325**
- Engine power: **31.32 kW / 42 HP**

### Cross-checked detailed fields
- Cylinders: **3**
- Rated RPM: **2000 RPM**
- Torque: **166 Nm**
- Gearbox: **8F+8R Synchro Shuttle** / side-shift AFD
- PTO: **39 HP**, MultiSpeed & Reverse PTO with independent PTO clutch lever
- Brakes: Oil immersed multi-disc
- Steering: Power steering
- Fuel tank: **42 L**
- Overall length: **3595 mm**
- Overall width: **1790 mm**
- Overall height: **2290 mm**
- Wheelbase: **1920 mm**
- Weight: **1770 kg**
- Ground clearance: **385 mm**
- Lifting capacity: **1800 kg**, Lift-O-Matic
- Tyres: **6x16 front / 13.6x28 rear**
- Drive: **2WD** in the detailed base record
- Warranty: **6 years T-warranty** in third-party current records
- Battery: **75 Ah** and alternator **35 A** in one detailed record

### Current successor / related model
New Holland's current website also lists **3230 TX Super** (2WD and 4WD), with 45 HP on the current Hindi page and 41 HP PTO headline. Treat it as a separate model/variant, not as the same record.

### Sources
- Official current 3230 TX: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx
- Official 3230 TX Super: https://agriculture.newholland.com/en/india/products/agricultural-tractors/3230-tx-super
- Detailed specification record: https://tractorgyan.com/tractor/new-holland-3230-tx/1444

Verification: **Manufacturer verified for current headline values; detailed fields cross-checked.**

---

# 2. CITY LIFE ELECTRIC RICKSHAWS

Manufacturer/brand: **CityLife / Dilli Electric Auto**
Official site: https://www.citylifeev.com/

## 2.1 Official model range currently exposed on CityLife site
- XV-850
- LI-PRIMA 2022
- Butterfly Deluxe (XV-850)
- Butterfly Super Deluxe (XV-850)
- Standard (XV-850)
- Standard+ (XV-850)
- School Type (XV-850)

CityLife also lists electric loaders:
- Loader (XV-MAX)
- Open Body Loader (XV-MAX)
- Closed Body Loader (LI-MAX)
- Closed Body Loader (XV-MAX)
- Garbage Loader (XV MAX)

## 2.2 Common official XV-850 / LI-PRIMA family fields
For the XV-850 and LI-PRIMA product pages, CityLife publishes:
- Seating capacity: **Driver + 4 passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Capacity range: **100 Ah–135 Ah**
- Front tyre size: **3-12 / 90-90-12 / 3.75-12** (site repeats this field as “Front” for both axle positions)
- Length: **2770 mm**
- Width: **985 mm**
- Height: **1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Maximum gradeability: **≤10** (the site omits a unit; store exactly as published and do not assume degrees/percent)
- Turning radius: **2.4 m**
- Front suspension: **Telescopic hydraulic shockers**
- Rear suspension: **Double movement leaf spring with hydraulic shockers**
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: the site says “48W”, which is almost certainly a publishing/typing issue; **do not convert this to 48 V in the master database without dealer/manufacturer confirmation**.

## 2.3 LI-PRIMA 2022 — independent specification cross-check
A current third-party specification record lists:
- Battery system: **48 V**
- Battery capacity: **135 Ah**
- Range: **90–100 km**
- Charging: **6–8 hours**
- Max speed: **25 km/h**
- GVW: **380 kg**
- Wheelbase: **2100 mm**
- Overall size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Turning radius: **2400 mm**
- Motor: Electric motor
- Gearbox: Automatic, **1 forward + 1 reverse**
- Seating: **D+4**
- Brakes: Drum

Use the above as a cross-check, not as the manufacturer's primary record.

## 2.4 CityLife Standard XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **60–80 km**
- Max speed: **23 km/h**
- Motor power listed by one portal: **850 W**
- Charging: **5–7 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.5 CityLife Standard+ XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–100 km**
- Max speed: **23 km/h**
- Charging: **6–8 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.6 CityLife School Type XV-850 — third-party detailed cross-check
- Battery capacity: **100 Ah**
- Range: **70–80 km**
- Max speed: **23 km/h**
- Max torque listed: **45 Nm**
- Charging time: **3–4 hours**
- GVW: **400 kg**
- Wheelbase: **2100 mm**
- Size: **2770 x 985 x 1730 mm**
- Ground clearance: **200 mm**
- Seating: **D+4**

## 2.7 CityLife Closed Body Loader (LI-MAX) — official page
- Seating: **Driver + 4 Passenger**
- Approx load capacity: **400 kg**
- Battery: **Lead acid**
- Battery capacity range: **100–135 Ah**
- Front brakes: Lever-operated drum
- Rear brakes: Brake-paddle-operated drum
- Parking brake: Mechanical hand lever
- Front tyre: **3-12 / 90-90-12 / 3.75-12**
- Dimensions: **2770 x 985 x 1730 mm**
- Wheelbase: **2100 mm**
- Ground clearance: **200 mm**
- Max gradeability: **≤10** (unit omitted by manufacturer page)
- Turning radius: **2.4 m**
- Front suspension: Telescopic hydraulic shockers
- Rear suspension: Double movement leaf spring + hydraulic shockers
- Controller: **50 A, 24 MOSFETs**
- Controller voltage: manufacturer page publishes “48W”; treat as unverified/likely typo

### Sources
- CityLife about/company: https://www.citylifeev.com/about
- Official e-rickshaw range: https://www.citylifeev.com/electric-vehicles-erickshaw
- XV-850: https://www.citylifeev.com/butterfly2020
- LI-PRIMA: https://www.citylifeev.com/li-prima2020
- Butterfly Deluxe: https://www.citylifeev.com/butterflydelux
- Butterfly Super Deluxe: https://www.citylifeev.com/butterflysuperdeluxe
- Standard: https://www.citylifeev.com/standard
- Standard+: https://www.citylifeev.com/standardplus
- School Type: https://www.citylifeev.com/schooltype
- LI-MAX: https://www.citylifeev.com/xv-maxclosedbody
- Third-party LI-PRIMA: https://trucks.cardekho.com/en/trucks/city-life/li-prima-2022/specifications
- Third-party Standard: https://trucks.cardekho.com/en/trucks/city-life/standard-xv850/specifications
- Third-party Standard+: https://trucks.cardekho.com/en/trucks/city-life/standard-plus-xv-850/specifications
- Third-party School: https://trucks.cardekho.com/en/trucks/city-life/school-type-xv-850/specifications

Verification: **Manufacturer model range and shared mechanical fields verified; some performance values are third-party because the official pages omit them or publish incomplete units.**

---

# 3. GREAVES ELECTRIC 3-WHEELERS

Manufacturer: **Greaves Electric Mobility Limited**
Official 3W site: https://3wheelers.greaveselectricmobility.com/

## 3.1 Greaves Eltra City XTRA — current electric passenger model

### Manufacturer-published current facts
- Variant: **Eltra City XTRA**
- True range: **up to 170 km** (manufacturer press release)
- Top speed: **60 km/h in Power Mode**
- Battery: **10.75 kWh LFP** according to current manufacturer product page/press material
- Motor: **9.5 kW PMS motor**
- 0–30 km/h: **6.4 seconds** (manufacturer product page)
- Digital cluster: **6.2-inch PMVA digital cluster** with DTE/navigation
- Mobile application / fleet management / remote diagnostics are marketed features
- Battery warranty: **5 years** advertised for the Eltra City XTRA
- Greaves 3W claims a national record of **324 km** on a single charge for a record-setting run; this is a record demonstration, **not the normal rated range**, and must never be shown in the app as customer range.
- Launch price announcement: **₹3,57,000 onwards** in the 17 October 2025 announcement. Do not use as today's OM Motors selling price.

### General Eltra family data from manufacturer brochure/current product page
- Peak power: **9.5 kW**
- Max torque: **49 Nm**
- Gearbox: **Single speed**
- Earlier brochure range: **105 km** for the Eltra family, while the current Eltra City XTRA is rated higher. Store each generation separately.
- Different Eltra cargo variants have different payloads; do not apply cargo payload to the passenger City variant.

### Current product page technical data exposed in the page for Eltra variants
The current Eltra page contains variant-level data including:
- Battery type: **LFP**
- Battery voltage: **51.2 V**
- Peak power: **9.5 kW**
- Charger: **2 kW**
- Transmission: **Single**
- Typical charging time on listed variants: **5–6 hours**
- Hydraulic drum brakes / drum depending variant
- Passenger/cargo variants have different dimensions, kerb weight and payload; use the exact sub-variant record.

### Sources
- Current Eltra page: https://3wheelers.greaveselectricmobility.com/eltra
- Greaves official press release (17 Aug 2026): https://greaveselectricmobility.com/press-release/greaves-electric-mobility-rolls-out-festive-offers-across-india-for-nexus-and-magnus-neo
- Greaves record announcement: https://greaveselectricmobility.com/press-release/greaves-electric-mobility-s-newly-launched-eltra-city-xtra-does-the-unbelievable-324-km-on-a-single-charge-sets-new-national-record
- Older official brochure: https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf

Verification: **Manufacturer verified.**

---

# 4. GREAVES CNG 3-WHEELERS

Current Greaves official brochure page lists the following CNG variants in its range:
- **Teja Super City EX**
- **Teja Super City**
- **Teja Super Cargo LB**
- **Teja Super Cargo**

## 4.1 Teja Super City EX — passenger CNG
### Manufacturer brochure / current product material
- Engine: **395 cc, 4S-SI, single-cylinder, water-cooled**
- Engine power: **7.25 kW**
- Maximum torque: **24.5 Nm**
- Claimed mileage: **39 km/kg***
- Fuel tank: **CNG 40 L + petrol 3 L**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- Gradeability: **18% / 10.2°**
- Wheelbase: **1930 mm** in the current combined brochure
- Tyre: **120/80 R12 tubeless**
- Payload: **334 kg**
- Warranty: **36 months / 1 lakh km***
- Current combined leaflet dimensions for Teja Super City EX: **2950 x 1500 x 1988 mm**
- Current combined leaflet kerb weight: **507 kg**
- Current combined leaflet GVW: **841 kg**

### Important source conflict
A dealer/third-party page published **2980 x 1500 x 1988 mm**, wheelbase **1890 mm**, kerb **267 kg**, GVW **601 kg**, which conflicts materially with the newer Greaves combined brochure. For the app, use the **newer manufacturer brochure values** and retain the third-party values only in source history.

## 4.2 Teja Super City — passenger CNG
Current Greaves combined brochure lists:
- Engine: **395 cc, 4S-SI, single-cylinder, water cooled**
- Power: **7.25 kW**
- Torque: **24.5 Nm**
- Mileage: **39 km/kg***
- Fuel tank: **CNG 40 L + petrol 3 L**
- Wheelbase: **1930 mm**
- Gradeability: **18% / 10.2°**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- GVW: **839 kg**
- Kerb: **509 kg**
- Payload: **330 kg**
- Tyre: **120/80 R12 tubeless**
- Warranty: **36 months / 1 lakh km***
- Dimensions: **2950 x 1484 x 1833 mm**

## 4.3 Teja Super Cargo LB
A Greaves brochure record gives:
- Engine: **395 cc, 4S-SI, single-cylinder, water cooled**
- Power: **7.25 kW**
- Torque: **24.5 Nm**
- Claimed mileage: **37 km/kg***
- Wheelbase: **2100 mm**
- Gradeability: **18% / 10.2°**
- Fuel tank: **40 L CNG**
- Gears: **4F+1R**
- Top speed: **59 km/h**
- GVW: **997 kg**
- Kerb weight: **523 kg**
- Payload: **474+ kg** in the brochure record; another textual summary says 483 kg. Store **474+ kg** as the exact brochure field and flag payload summary conflicts for dealer verification.
- Tyre: **120/80 R12 tubeless**
- Deck length: **6 ft**
- Cargo box: **1896 x 1472 x 364 mm**
- Warranty: **36 months / 1 lakh km***

### Sources
- Current Greaves 3W brochure page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Combined 2025 leaflet: https://ampere.sgp1.cdn.digitaloceanspaces.com/website/brochure/L5%20Combined%20Leaflet%20-%2025-09.pdf
- Teja Super Cargo LB source record: https://www.scribd.com/document/972843733/Greaves-CNG-Teja-NEW-Super-Cargo-LB
- Teja passenger cross-check: https://vardhmanauto.com/greaves-teja-cng-passenger/

Verification: **Manufacturer brochure verified for core fields; older dealer records contain conflicts and should not overwrite current manufacturer data.**

---

# 5. GREAVES DIESEL 3-WHEELERS

Current Greaves brochure page lists:
- D435 Super City EX
- D435 City EX
- D435 Super Cargo LB
- D435 Cargo LB
- D435 Super Cargo

## 5.1 D435 Passenger / D435 City family
Cross-checked published data for the D435 passenger/city family:
- Engine: **435 cc, single-cylinder diesel**
- Max power: **5.7 kW @ 3600 RPM**
- Max torque: **19 Nm @ 2200–2400 RPM**
- Gears: **4 forward + 1 reverse**
- Fuel tank: **10.5 L**
- Top speed: **55 km/h**
- D435 Passenger kerb weight: **456 kg** in the official/Greaves brochure source
- Passenger D435 GVW: **786 kg** in the official brochure source
- Passenger payload: **330 kg** in the official brochure source

### D435 City EX current market cross-check
A current market record for D435 City reports:
- Power: **7.6 HP**
- GVW: **786 kg**
- Wheelbase: **1930 mm**
- Fuel tank: **10.5 L**
- Payload: **330 kg**
- Mileage: **20–25 km/l** (third-party claim; do not present as Greaves official mileage)

Use the exact Greaves variant/brochure for your dealership inventory record.

## 5.2 D435 Cargo / Super Cargo
Greaves' older official all-brochure record includes a D435 cargo variant with:
- Engine: **435 cc single-cylinder diesel, air cooled**
- Power: **5.7 kW @ 3600 RPM**
- Torque: **19 Nm @ 2200–2400 RPM**
- Gear: **4F+1R**
- GVW: **997 kg**
- Payload: **462 kg**
- Max speed: **45 km/h**
- Fuel tank: **10.5 L**

A newer D435 Super Cargo LB may differ. Record it as a separate variant rather than inheriting these values.

## 5.3 Greaves D599+ Diesel variants
The manufacturer brochure/search material also records D599+:

### Passenger
- Engine: **599 cc, single-cylinder diesel, water cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **790 kg**
- Payload: **310 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Pickup/Cargo
- Engine: **599 cc, single-cylinder diesel, air cooled**
- Power: **7.0 kW @ 3600 RPM**
- Torque: **23.5 Nm @ 2200 ± 200 rpm**
- Gear: **4F+1R**
- Kerb: **480 kg**
- GVW: **980 kg**
- Payload: **500 kg**
- Max speed: **55 km/h**
- Fuel tank: **10.5 L**

### Sources
- Greaves current 3W range: https://3wheelers.greaveselectricmobility.com/
- Current brochure download page: https://3wheelers.greaveselectricmobility.com/download-brochure
- Official all-brochure: https://3wheelers.greaveselectricmobility.com/pdfs/all_brochure.pdf
- D435 passenger brochure record: https://3wheelers.greaveselectricmobility.com/pdfs/brochure.pdf
- D435 City third-party cross-check: https://trucks.tractorjunction.com/en/greaves-truck/d-435-city/

Verification: **Core D435/D599 data sourced from Greaves brochure material; current Super variants need exact dealer/OEM brochure attachment before final stock/master-data publication.**

---

# 6. OKAYA E-RICKSHAW BATTERIES

Brand: **OKAYA**
Official site: https://www.okaya.in/

## 6.1 Current official e-rickshaw battery range found
The current Okaya product listing publishes:

| SKU / Model | Capacity | Technology | Nominal Voltage | Published Warranty | Current website retail price* |
|---|---:|---|---:|---:|---:|
| OPERT13507 ECO Rider | 120 Ah | Tubular | 12 V | 7 months | ₹11,390 incl. taxes |
| OPERT13509 PRO Rider | 120 Ah | Tubular | 12 V | 9 months | ₹11,490 incl. taxes |
| OPERT14012 PRO+ Rider | 125 Ah | Tubular | 12 V | 12 months | ₹13,490 incl. taxes |
| OPERT15012 PRO+ Rider | 135 Ah | Tubular | 12 V | 12 months | ₹13,990 incl. taxes |
| OPERT16015 MAX Rider | 145 Ah | Tubular | 12 V on listing; 15 months on product page | 15 months | ₹15,490 incl. taxes |

`*Website retail prices are dynamic online prices, not OM Motors selling prices. Do not hardcode them as dealership prices.`

### Official product details
#### OPERT13507
- Capacity @ C20: **120 Ah**
- Dimensions (L x W x H up to terminal): **410 x 172 x 235 mm ±2 mm**
- Warranty: **7 months**
- Nominal voltage: **12 V**
- Tubular lead-acid design
- Product line: **ECO Rider**
- Manufacturer feature claims: extra mileage, longer life, faster recharge, 99.98% pure lead, special paste formulation, low-antimony alloy, factory charged, paperless warranty

#### OPERT13509
- Capacity @ C20: **120 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **9 months**
- Nominal voltage: **12 V**
- Product line: **PRO Rider**

#### OPERT14012
- Capacity @ C20: **125 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT15012
- Capacity @ C20: **135 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **12 months**
- Nominal voltage: **12 V**
- Product line: **PRO+ Rider**

#### OPERT16015
- Capacity @ C20: **145 Ah**
- Dimensions: **410 x 172 x 275 mm ±2 mm**
- Warranty: **15 months**
- Nominal voltage: **12 V**
- Product line: **MAX Rider**

### General Okaya e-rickshaw facts published by Okaya
- Most e-rickshaws use **four 12 V batteries in series** for a 48 V system.
- Okaya states e-rickshaw battery capacity offerings include 120 Ah, 125 Ah, 135 Ah and 145 Ah.
- Okaya states typical real-world battery life can be **12–18 months** depending on use, charging and maintenance; this is a general consumer guidance statement, **not the warranty period**.
- Okaya FAQ says full-charge range can be **70–120 km**, depending on capacity and driving conditions; do not attach this range automatically to every battery SKU.

### Additional legacy Okaya record
An older Okaya drawing for **OTER 16012** states:
- Type: lead-acid tubular
- Nominal voltage: **12 V**
- Capacity: **90 Ah C5 corrected at 30°C**
- Vehicle application: electric vehicle
- Dimensions: **408±3 x 172±3 x 234±3 mm overall**
- Warranty printed on drawing: **12 months**
This is a historical technical drawing and should be stored as `legacy_model=true`, not mixed with the current OPERT range.

### Sources
- Current Okaya e-rickshaw listing: https://www.okaya.in/product-listing/e-rickshaw-battery
- OPERT13507: https://www.okaya.in/product/opert13507
- OPERT13509: https://www.okaya.in/product/opert13509
- OPERT14012: https://www.okaya.in/product/opert14012
- OPERT15012: https://www.okaya.in/product/opert15012-135ah
- OPERT16015: https://www.okaya.in/product/opert16015
- Okaya mobility page: https://www.okaya.in/index.php/mobility-solution/e-rickshaw-battery
- Okaya FAQ: https://www.okaya.in/faqs
- Legacy technical drawing: https://www.okaya.in/storage/images/gallery/1685434338.pdf

Verification: **Manufacturer verified.**

---

# 7. TRONTEK E-RICKSHAW LITHIUM BATTERIES

## Important naming note
The manufacturer currently uses the spelling **Trontek Electronics Ltd / Trontek**, not “Trontec”. For the app, store:
- `brand_display_name = Trontek`
- `alternate_search_terms = Trontec, TronTek`

Official site: https://trontek.com/
Official e-rickshaw battery page: https://trontek.com/products/e-rickshaw-lithium-battery/

## 7.1 Current published Trontek e-rickshaw lithium variants
The official page currently exposes the following electrical variants:

| Model | Nominal Voltage | Capacity | Energy |
|---|---:|---:|---:|
| 51V 105Ah | 51 V | 105 Ah | 5.376 kWh |
| 51V 132Ah | 51 V | 132 Ah | 6.758 kWh |
| 51V 153Ah | 51 V | 153 Ah | 7.834 kWh |
| 51V 232Ah | 51 V | 232 Ah | 11.878 kWh |
| 61V 105Ah | 61 V | 105 Ah | 6.405 kWh |
| 61V 132Ah | 61 V | 132 Ah | 8.052 kWh |
| 61V 153Ah | 61 V | 153 Ah | 9.333 kWh |
| 61V 232Ah | 61 V | 232 Ah | 14.152 kWh |
| 64V 105Ah | 64 V | 105 Ah | 6.72 kWh |
| 64V 132Ah | 64 V | 132 Ah | 8.448 kWh |
| 72V 232Ah | 72 V | 232 Ah | 16.704 kWh |

### Technology / safety claims published by Trontek
- Chemistry: **LiFePO4 / LFP** for the e-rickshaw lithium battery range
- Smart/BMS-style protection against over-charge and over-discharge
- Short-circuit protection
- Acupuncture test resistance claim
- Thermal shock resistance claim
- Vibration and shock resistance claim
- Steady output voltage
- Low self-discharge
- High temperature performance claims
- Official page describes these as suitable for commercial e-rickshaw operation

### What is NOT safe to hardcode yet
The currently indexed product page exposes voltage/capacity/energy, but does not consistently expose for every SKU:
- dimensions
- weight
- charge current
- discharge current
- cycle count
- warranty months
- exact BMS communications
- price
Therefore those fields should be `null` until the exact Trontek datasheet used by OM Motors is uploaded/verified.

### Separate research note
A government/public-sector industry document references Trontec/Trontek among Indian lithium battery pack assemblers, but this does not substitute for an individual product datasheet.

### Sources
- Trontek official home: https://trontek.com/
- Official e-rickshaw lithium page: https://trontek.com/products/e-rickshaw-lithium-battery/
- Trontek e-rickshaw battery technology article: https://trontek.com/blog/complete-guide-to-e-rickshaw-lithium-batteries-in-india/
- Public-sector industry study referencing Trontek: https://cdnbbsr.s3waas.gov.in/s3716e1b8c6cd17b771da77391355749f3/uploads/2023/12/202312011172653171.pdf

Verification: **Manufacturer verified for the published electrical range; missing mechanical/warranty/price fields intentionally left unpopulated.**

---

# 8. APP DATABASE FIELD DESIGN FOR THESE PRODUCTS

Every product/model record should include:

```text
product_id
brand
product_family
model_name
variant_name
category
subcategory
status (active/discontinued/legacy)
model_year_start
model_year_end
fuel_or_energy_type
engine_model
engine_type
engine_displacement_cc
cylinders
power_hp
power_kw
rated_rpm
torque_nm
transmission_type
gearbox
forward_gears
reverse_gears
clutch_type
pto_type
pto_power_hp
pto_rpm
fuel_tank_l
battery_voltage_v
battery_capacity_ah
battery_chemistry
battery_energy_kwh
charging_time_hours
range_km
max_speed_kmph
payload_kg
gvw_kg
kerb_weight_kg
lifting_capacity_kg
gradeability
ground_clearance_mm
wheelbase_mm
overall_length_mm
overall_width_mm
overall_height_mm
front_tyre
rear_tyre
steering_type
brake_type
front_suspension
rear_suspension
controller_rating
controller_voltage
warranty_duration_months
warranty_distance_km
warranty_hours
features[]
applications[]
compatible_implements[]
compatible_parts[]
brochure_url
product_page_url
source_url[]
source_type[]
source_checked_on
verification_status
notes
```

---

# 9. SPECIAL DATABASE RULES FOR OM MOTORS

## 9.1 Do not treat brochure specifications as inventory
Product specifications describe the model. Inventory describes the physical unit currently owned by OM Motors.

Example:

```text
MODEL
New Holland 3600-2 TX

INVENTORY UNIT
Chassis No: XXXXX
Engine No: XXXXX
Color: XXXXX
Arrival Date: XXXXX
Purchase Bill: PB-XXXX
Current Status: In Stock / Reserved / Sold / Delivered
```

## 9.2 Do not use public price pages as OM Motors price masters
Create separate fields:

```text
manufacturer_list_price
om_motors_selling_price
om_motors_effective_from
om_motors_effective_to
branch_price
customer_specific_discount
manager_approved_discount
```

## 9.3 Battery serial-level records
For every physical battery:

```text
battery_unit_id
brand
model_sku
serial_number
manufacturing_date
purchase_date
purchase_bill_id
supplier_id
purchase_cost
stock_location
sale_date
sale_invoice_id
customer_id
vehicle_id
installation_date
warranty_start_date
warranty_end_date
warranty_status
warranty_claim_id
current_status
```

## 9.4 Vehicle serial-level records
For every tractor/rickshaw:

```text
vehicle_unit_id
brand
model_id
variant_id
chassis_number
engine_number
motor_number
battery_number
manufacturing_month
manufacturing_year
arrival_date
purchase_bill_id
purchase_cost
stock_status
customer_id
sale_invoice_id
sale_date
delivery_date
pdi_id
warranty_start
warranty_end
```

---

# 10. FIND YOUR VEHICLE — RULE DATA

The recommendation engine should use verified structured attributes only.

## Tractor questions
- land area
- crop(s)
- primary use
- heavy/light work
- required implement
- budget
- 2WD/4WD preference
- lifting requirement
- road/haulage usage
- narrow-row/orchard requirement

### Example rule patterns
- If customer needs higher lifting capacity and heavy implements, prioritize models with **1700–2000 kg+** lifting capacity.
- If customer specifically needs 4WD, exclude 2WD-only variants.
- If customer requires an implement, show only models marked compatible with that implement.
- Never claim a tractor is “best” solely from HP; the recommendation must consider budget, lifting, drive, implement compatibility, and intended application.

## E-rickshaw questions
- daily distance
- passengers
- payload
- charging access
- city/intercity use
- desired speed
- battery preference
- budget
- expected operating hours

## CNG/diesel questions
- daily km
- passenger vs cargo
- expected payload
- fuel availability
- grade/terrain
- required speed
- budget
- maintenance preference

---

# 11. PRODUCT COMPARISON ENGINE

Comparison must compare like-for-like variant records.

Recommended fields:

```text
price
power_hp
torque_nm
battery_capacity_ah
battery_energy_kwh
range_km
max_speed_kmph
payload_kg
gvw_kg
fuel_tank_l
charging_time_hours
lifting_capacity_kg
gearbox
gears
wheelbase_mm
ground_clearance_mm
warranty
2wd_4wd
compatible_implements
recommended_use
```

For fields with unavailable values, show **“Not published”** rather than 0.

---

# 12. SOURCING & REFRESH POLICY

For the production app:
1. Store source URL with every product record.
2. Store the date the specification was checked.
3. Store a source priority: `OEM`, `OEM brochure`, `government/test`, `reputable secondary`, `dealer`, `marketplace`.
4. Never overwrite a field silently after a source update.
5. Keep an audit history of specification changes.
6. Require manager/admin approval before publishing changed public product specs.
7. Attach the exact brochure PDF used to verify the model.

---

# 13. ITEMS THAT STILL REQUIRE OM MOTORS-SPECIFIC INPUT

The research above deliberately does **not** invent:
- OM Motors purchase price
- OM Motors selling price
- current local stock quantity
- dealership-specific discounts
- dealer margin
- exact current on-road price
- exact finance/NBFC offers available through OM Motors
- OM Motors warranty extension or goodwill policy
- exact parts inventory
- exact implement inventory
- OM Motors service labour rates
- exact current Greaves Super variant quotation data where the manufacturer page does not expose all fields
- Trontek SKU warranty/dimensions where the official indexed product page does not publish them

These should be entered through the OM Motors admin panel.

---

# 14. SOURCE PRIORITY SUMMARY

### New Holland
**Primary:** New Holland India official product pages and brochures.

### CityLife
**Primary:** CityLife official product pages; third-party values only where the official page is incomplete.

### Greaves
**Primary:** Greaves Electric Mobility / Greaves 3W official pages and brochures.

### Okaya
**Primary:** Okaya official product pages and product listing.

### Trontek
**Primary:** Trontek official product pages.

---

# 15. IMPORTANT IMPLEMENTATION NOTE

The app should support **model generations and variant revisions**, not one flat product row per model name.

For example:

```text
New Holland
  └── 3630 Family
      ├── 3630 TX Plus+ (legacy)
      ├── 3630 TX Super
      ├── 3630 TX Super Plus+ 2WD
      ├── 3630 TX Super Plus+ 4WD
      └── 3630 TX Special Edition 2WD / 4WD
```

Similarly:

```text
Greaves
  └── Teja
      ├── Teja Super City
      ├── Teja Super City EX
      ├── Teja Super Cargo
      └── Teja Super Cargo LB
```

This avoids incorrect comparisons, incorrect quotations, and incorrect parts compatibility.

---

# 16. VERIFIED RESEARCH SNAPSHOT

At the date of this research, the strongest verified manufacturer-backed data in this pack are:

- **New Holland 3600-2 TX:** 49.5 HP, FPT S8000, 8F+2R / creeper option, 1700 kg lift, 60 L tank, power steering, oil-immersed multi-disc brakes.
- **New Holland 3230 TX:** 42 HP, 39 HP PTO, 166 Nm torque, 42 L tank, 1800 kg lift in the detailed record.
- **New Holland 3600 TX Super Heritage Edition:** 47 HP engine record, 1800 kg lift, 2WD/4WD, EPTRA PTO, FPT engine.
- **New Holland 3630 family:** current Super/Super Plus+/Special Edition family with FPT S8000, Sensomatic24, 1700/2000 kg lifting options and 2WD/4WD variants depending model.
- **CityLife XV-850 family:** D+4 passenger, approx. 400 kg load capacity, 100–135 Ah lead-acid range, 2770 x 985 x 1730 mm, 2100 mm wheelbase.
- **Greaves Eltra City XTRA:** 170 km true range, 60 km/h Power Mode, 10.75 kWh LFP, 9.5 kW PMS motor, 5-year battery warranty.
- **Greaves Teja Super City EX:** 395 cc water-cooled CNG engine, 7.25 kW, 24.5 Nm, 39 km/kg claim, 4F+1R, 59 km/h, 334 kg payload, 36 months/1 lakh km warranty.
- **Greaves D435 passenger family:** 435 cc diesel, 5.7 kW, 19 Nm, 4F+1R, 10.5 L tank, 55 km/h, 330 kg payload in the published passenger record.
- **Okaya current E-rickshaw batteries:** OPERT13507 120 Ah/7 months; OPERT13509 120 Ah/9 months; OPERT14012 125 Ah/12 months; OPERT15012 135 Ah/12 months; OPERT16015 145 Ah/15 months.
- **Trontek current e-rickshaw lithium:** 51 V, 61 V, 64 V and 72 V families with capacities from 105 Ah through 232 Ah and published energy values from 5.376 kWh to 16.704 kWh.

