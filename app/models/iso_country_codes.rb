# Single source of truth for ISO 3166-1 alpha-2 ↔ alpha-3 conversion. Used by
# RegionsController for mapping MapTiler/Nominatim country_codes (alpha-2) to
# our GeoNames-seeded iso_code column (alpha-3), and by the regions:seed_*
# rake tasks for the reverse direction during city seeding.
module IsoCountryCodes
  A2_TO_A3 = {
    "AD" => "AND", "AE" => "ARE", "AF" => "AFG", "AG" => "ATG", "AI" => "AIA", "AL" => "ALB", "AM" => "ARM", "AO" => "AGO",
    "AR" => "ARG", "AS" => "ASM", "AT" => "AUT", "AU" => "AUS", "AW" => "ABW", "AX" => "ALA", "AZ" => "AZE", "BA" => "BIH",
    "BB" => "BRB", "BD" => "BGD", "BE" => "BEL", "BF" => "BFA", "BG" => "BGR", "BH" => "BHR", "BI" => "BDI", "BJ" => "BEN",
    "BL" => "BLM", "BM" => "BMU", "BN" => "BRN", "BO" => "BOL", "BR" => "BRA", "BS" => "BHS", "BT" => "BTN", "BW" => "BWA",
    "BY" => "BLR", "BZ" => "BLZ", "CA" => "CAN", "CD" => "COD", "CF" => "CAF", "CG" => "COG", "CH" => "CHE", "CI" => "CIV",
    "CK" => "COK", "CL" => "CHL", "CM" => "CMR", "CN" => "CHN", "CO" => "COL", "CR" => "CRI", "CU" => "CUB", "CV" => "CPV",
    "CW" => "CUW", "CY" => "CYP", "CZ" => "CZE", "DE" => "DEU", "DJ" => "DJI", "DK" => "DNK", "DM" => "DMA", "DO" => "DOM",
    "DZ" => "DZA", "EC" => "ECU", "EE" => "EST", "EG" => "EGY", "ER" => "ERI", "ES" => "ESP", "ET" => "ETH", "FI" => "FIN",
    "FJ" => "FJI", "FK" => "FLK", "FM" => "FSM", "FO" => "FRO", "FR" => "FRA", "GA" => "GAB", "GB" => "GBR", "GD" => "GRD",
    "GE" => "GEO", "GF" => "GUF", "GG" => "GGY", "GH" => "GHA", "GI" => "GIB", "GL" => "GRL", "GM" => "GMB", "GN" => "GIN",
    "GP" => "GLP", "GQ" => "GNQ", "GR" => "GRC", "GT" => "GTM", "GU" => "GUM", "GW" => "GNB", "GY" => "GUY", "HK" => "HKG",
    "HN" => "HND", "HR" => "HRV", "HT" => "HTI", "HU" => "HUN", "ID" => "IDN", "IE" => "IRL", "IL" => "ISR", "IM" => "IMN",
    "IN" => "IND", "IO" => "IOT", "IQ" => "IRQ", "IR" => "IRN", "IS" => "ISL", "IT" => "ITA", "JE" => "JEY", "JM" => "JAM",
    "JO" => "JOR", "JP" => "JPN", "KE" => "KEN", "KG" => "KGZ", "KH" => "KHM", "KI" => "KIR", "KM" => "COM", "KN" => "KNA",
    "KP" => "PRK", "KR" => "KOR", "KW" => "KWT", "KY" => "CYM", "KZ" => "KAZ", "LA" => "LAO", "LB" => "LBN", "LC" => "LCA",
    "LI" => "LIE", "LK" => "LKA", "LR" => "LBR", "LS" => "LSO", "LT" => "LTU", "LU" => "LUX", "LV" => "LVA", "LY" => "LBY",
    "MA" => "MAR", "MC" => "MCO", "MD" => "MDA", "ME" => "MNE", "MF" => "MAF", "MG" => "MDG", "MH" => "MHL", "MK" => "MKD",
    "ML" => "MLI", "MM" => "MMR", "MN" => "MNG", "MO" => "MAC", "MP" => "MNP", "MQ" => "MTQ", "MR" => "MRT", "MS" => "MSR",
    "MT" => "MLT", "MU" => "MUS", "MV" => "MDV", "MW" => "MWI", "MX" => "MEX", "MY" => "MYS", "MZ" => "MOZ", "NA" => "NAM",
    "NC" => "NCL", "NE" => "NER", "NF" => "NFK", "NG" => "NGA", "NI" => "NIC", "NL" => "NLD", "NO" => "NOR", "NP" => "NPL",
    "NR" => "NRU", "NU" => "NIU", "NZ" => "NZL", "OM" => "OMN", "PA" => "PAN", "PE" => "PER", "PF" => "PYF", "PG" => "PNG",
    "PH" => "PHL", "PK" => "PAK", "PL" => "POL", "PM" => "SPM", "PN" => "PCN", "PR" => "PRI", "PS" => "PSE", "PT" => "PRT",
    "PW" => "PLW", "PY" => "PRY", "QA" => "QAT", "RE" => "REU", "RO" => "ROU", "RS" => "SRB", "RU" => "RUS", "RW" => "RWA",
    "SA" => "SAU", "SB" => "SLB", "SC" => "SYC", "SD" => "SDN", "SE" => "SWE", "SG" => "SGP", "SH" => "SHN", "SI" => "SVN",
    "SJ" => "SJM", "SK" => "SVK", "SL" => "SLE", "SM" => "SMR", "SN" => "SEN", "SO" => "SOM", "SR" => "SUR", "SS" => "SSD",
    "ST" => "STP", "SV" => "SLV", "SX" => "SXM", "SY" => "SYR", "SZ" => "SWZ", "TC" => "TCA", "TD" => "TCD", "TG" => "TGO",
    "TH" => "THA", "TJ" => "TJK", "TK" => "TKL", "TL" => "TLS", "TM" => "TKM", "TN" => "TUN", "TO" => "TON", "TR" => "TUR",
    "TT" => "TTO", "TV" => "TUV", "TW" => "TWN", "TZ" => "TZA", "UA" => "UKR", "UG" => "UGA", "US" => "USA", "UY" => "URY",
    "UZ" => "UZB", "VA" => "VAT", "VC" => "VCT", "VE" => "VEN", "VG" => "VGB", "VI" => "VIR", "VN" => "VNM", "VU" => "VUT",
    "WF" => "WLF", "WS" => "WSM", "XK" => "KOS", "YE" => "YEM", "YT" => "MYT", "ZA" => "ZAF", "ZM" => "ZMB", "ZW" => "ZWE"
  }.freeze

  A3_TO_A2 = A2_TO_A3.invert.freeze

  def self.alpha3(alpha2)
    return nil unless alpha2
    A2_TO_A3[alpha2.upcase]
  end

  def self.alpha2(alpha3)
    return nil unless alpha3
    A3_TO_A2[alpha3.upcase]
  end
end
