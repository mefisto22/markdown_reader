import Foundation

/// `:shortcode:` → emoji. GitHub's own aliases for the frequently used
/// emoji come first; every other emoji is reachable by its Unicode name in
/// snake case (`:sunflower:`, `:hot_beverage:`, `:face_with_tears_of_joy:`),
/// which is how most GitHub names are formed.
enum EmojiShortcodes {
    static func emoji(for name: String) -> String? {
        aliases[name] ?? unicodeNames[name] ?? flags[name]
    }

    /// Country flags by English name (`:hungary:`, `:germany:`), from the
    /// system's region names.
    private static let flags: [String: String] = {
        var result: [String: String] = [:]
        let english = Locale(identifier: "en_US")
        for region in Locale.Region.isoRegions where region.identifier.count == 2 {
            guard let name = english.localizedString(forRegionCode: region.identifier) else { continue }
            var key = ""
            for ch in name.lowercased() {
                if ch.isLetter || ch.isNumber { key.append(ch) } else if !key.hasSuffix("_") { key.append("_") }
            }
            while key.hasSuffix("_") { key.removeLast() }
            let flag = region.identifier.uppercased().unicodeScalars
                .compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 0x41) }
                .map(String.init).joined()
            result[key] = flag
        }
        return result
    }()

    private static let aliases: [String: String] = [
        // Smileys and people
        "smile": "😄", "smiley": "😃", "grinning": "😀", "grin": "😁", "laughing": "😆", "satisfied": "😆",
        "sweat_smile": "😅", "joy": "😂", "rofl": "🤣", "relaxed": "☺️", "blush": "😊", "innocent": "😇",
        "slightly_smiling_face": "🙂", "upside_down_face": "🙃", "wink": "😉", "relieved": "😌",
        "heart_eyes": "😍", "smiling_face_with_three_hearts": "🥰", "kissing_heart": "😘", "kissing": "😗",
        "yum": "😋", "stuck_out_tongue": "😛", "stuck_out_tongue_winking_eye": "😜", "zany_face": "🤪",
        "stuck_out_tongue_closed_eyes": "😝", "money_mouth_face": "🤑", "hugs": "🤗", "hugging_face": "🤗",
        "thinking": "🤔", "thinking_face": "🤔", "zipper_mouth_face": "🤐", "raised_eyebrow": "🤨",
        "neutral_face": "😐", "expressionless": "😑", "no_mouth": "😶", "smirk": "😏", "unamused": "😒",
        "roll_eyes": "🙄", "grimacing": "😬", "lying_face": "🤥", "pensive": "😔", "sleepy": "😪",
        "drooling_face": "🤤", "sleeping": "😴", "mask": "😷", "face_with_thermometer": "🤒",
        "nauseated_face": "🤢", "vomiting_face": "🤮", "sneezing_face": "🤧", "hot_face": "🥵",
        "cold_face": "🥶", "dizzy_face": "😵", "exploding_head": "🤯", "cowboy_hat_face": "🤠",
        "partying_face": "🥳", "sunglasses": "😎", "nerd_face": "🤓", "monocle_face": "🧐",
        "confused": "😕", "worried": "😟", "slightly_frowning_face": "🙁", "frowning_face": "☹️",
        "open_mouth": "😮", "hushed": "😯", "astonished": "😲", "flushed": "😳", "pleading_face": "🥺",
        "frowning": "😦", "anguished": "😧", "fearful": "😨", "cold_sweat": "😰",
        "disappointed_relieved": "😥", "cry": "😢", "sob": "😭", "scream": "😱", "confounded": "😖",
        "persevere": "😣", "disappointed": "😞", "sweat": "😓", "weary": "😩", "tired_face": "😫",
        "yawning_face": "🥱", "triumph": "😤", "rage": "😡", "pout": "😡", "angry": "😠",
        "cursing_face": "🤬", "smiling_imp": "😈", "imp": "👿", "skull": "💀", "poop": "💩", "hankey": "💩",
        "shit": "💩", "clown_face": "🤡", "japanese_ogre": "👹", "ghost": "👻", "alien": "👽",
        "space_invader": "👾", "robot": "🤖", "smiley_cat": "😺", "heart_eyes_cat": "😻",
        "see_no_evil": "🙈", "hear_no_evil": "🙉", "speak_no_evil": "🙊",
        "wave": "👋", "raised_back_of_hand": "🤚", "raised_hand": "✋", "hand": "✋", "vulcan_salute": "🖖",
        "ok_hand": "👌", "pinched_fingers": "🤌", "pinching_hand": "🤏", "v": "✌️", "crossed_fingers": "🤞",
        "love_you_gesture": "🤟", "metal": "🤘", "call_me_hand": "🤙", "point_left": "👈",
        "point_right": "👉", "point_up_2": "👆", "point_down": "👇", "point_up": "☝️", "middle_finger": "🖕",
        "fu": "🖕", "+1": "👍", "thumbsup": "👍", "-1": "👎", "thumbsdown": "👎", "fist": "✊",
        "fist_raised": "✊", "facepunch": "👊", "punch": "👊", "fist_oncoming": "👊", "clap": "👏",
        "raised_hands": "🙌", "open_hands": "👐", "palms_up_together": "🤲", "handshake": "🤝",
        "pray": "🙏", "writing_hand": "✍️", "nail_care": "💅", "selfie": "🤳", "muscle": "💪",
        "eyes": "👀", "eye": "👁️", "brain": "🧠", "tongue": "👅", "lips": "👄", "baby": "👶",
        "child": "🧒", "boy": "👦", "girl": "👧", "adult": "🧑", "man": "👨", "woman": "👩",
        "older_man": "👴", "older_woman": "👵", "person_frowning": "🙍", "bow": "🙇", "facepalm": "🤦",
        "shrug": "🤷", "man_shrugging": "🤷‍♂️", "woman_shrugging": "🤷‍♀️", "technologist": "🧑‍💻",
        "man_technologist": "👨‍💻", "woman_technologist": "👩‍💻", "detective": "🕵️", "construction_worker": "👷",
        "ninja": "🥷", "santa": "🎅", "superhero": "🦸", "mage": "🧙", "runner": "🏃", "running": "🏃",
        "dancer": "💃", "walking": "🚶", "family": "👪", "busts_in_silhouette": "👥", "bust_in_silhouette": "👤",
        "footprints": "👣",
        // Hearts and symbols
        "heart": "❤️", "orange_heart": "🧡", "yellow_heart": "💛", "green_heart": "💚", "blue_heart": "💙",
        "purple_heart": "💜", "black_heart": "🖤", "white_heart": "🤍", "brown_heart": "🤎",
        "broken_heart": "💔", "heavy_heart_exclamation": "❣️", "two_hearts": "💕", "revolving_hearts": "💞",
        "heartbeat": "💓", "heartpulse": "💗", "sparkling_heart": "💖", "cupid": "💘", "gift_heart": "💝",
        "kiss": "💋", "100": "💯", "anger": "💢", "boom": "💥", "collision": "💥", "dizzy": "💫",
        "sweat_drops": "💦", "dash": "💨", "hole": "🕳️", "bomb": "💣", "speech_balloon": "💬",
        "thought_balloon": "💭", "zzz": "💤", "fire": "🔥", "sparkles": "✨", "star": "⭐", "star2": "🌟",
        "stars": "🌠", "zap": "⚡", "snowflake": "❄️", "sunny": "☀️", "cloud": "☁️", "umbrella": "☔",
        "rainbow": "🌈", "ocean": "🌊", "droplet": "💧", "earth_africa": "🌍", "earth_americas": "🌎",
        "earth_asia": "🌏", "globe_with_meridians": "🌐", "crescent_moon": "🌙", "full_moon": "🌕",
        "new_moon": "🌑", "tornado": "🌪️", "fog": "🌫️",
        "white_check_mark": "✅", "heavy_check_mark": "✔️", "ballot_box_with_check": "☑️", "x": "❌",
        "negative_squared_cross_mark": "❎", "heavy_multiplication_x": "✖️", "heavy_plus_sign": "➕",
        "heavy_minus_sign": "➖", "heavy_division_sign": "➗", "question": "❓", "grey_question": "❔",
        "exclamation": "❗", "heavy_exclamation_mark": "❗", "grey_exclamation": "❕", "bangbang": "‼️",
        "interrobang": "⁉️", "warning": "⚠️", "no_entry": "⛔", "no_entry_sign": "🚫", "stop_sign": "🛑",
        "radioactive": "☢️", "biohazard": "☣️", "recycle": "♻️", "infinity": "♾️", "copyright": "©️",
        "registered": "®️", "tm": "™️", "information_source": "ℹ️", "abc": "🔤", "new": "🆕", "free": "🆓",
        "up": "🆙", "cool": "🆒", "ok": "🆗", "sos": "🆘", "top": "🔝", "soon": "🔜", "back": "🔙",
        "end": "🔚", "on": "🔛", "arrow_up": "⬆️", "arrow_down": "⬇️", "arrow_left": "⬅️",
        "arrow_right": "➡️", "arrow_upper_right": "↗️", "arrow_lower_right": "↘️", "arrow_lower_left": "↙️",
        "arrow_upper_left": "↖️", "arrow_up_down": "↕️", "left_right_arrow": "↔️", "arrows_counterclockwise": "🔄",
        "arrows_clockwise": "🔃", "leftwards_arrow_with_hook": "↩️", "arrow_right_hook": "↪️",
        "arrow_forward": "▶️", "arrow_backward": "◀️", "fast_forward": "⏩", "rewind": "⏪",
        "twisted_rightwards_arrows": "🔀", "repeat": "🔁", "pause_button": "⏸️", "stop_button": "⏹️",
        "record_button": "⏺️", "red_circle": "🔴", "orange_circle": "🟠", "yellow_circle": "🟡",
        "green_circle": "🟢", "large_blue_circle": "🔵", "blue_circle": "🔵", "purple_circle": "🟣",
        "black_circle": "⚫", "white_circle": "⚪", "red_square": "🟥", "green_square": "🟩",
        "blue_square": "🟦", "black_large_square": "⬛", "white_large_square": "⬜",
        "small_red_triangle": "🔺", "small_red_triangle_down": "🔻", "large_orange_diamond": "🔶",
        "large_blue_diamond": "🔷", "small_orange_diamond": "🔸", "small_blue_diamond": "🔹",
        "hash": "#️⃣", "asterisk": "*️⃣", "zero": "0️⃣", "one": "1️⃣", "two": "2️⃣", "three": "3️⃣",
        "four": "4️⃣", "five": "5️⃣", "six": "6️⃣", "seven": "7️⃣", "eight": "8️⃣", "nine": "9️⃣",
        "keycap_ten": "🔟", "1234": "🔢", "symbols": "🔣", "capital_abcd": "🔠", "abcd": "🔡",
        "trophy": "🏆", "medal_sports": "🏅", "1st_place_medal": "🥇", "2nd_place_medal": "🥈",
        "3rd_place_medal": "🥉", "dart": "🎯", "game_die": "🎲", "jigsaw": "🧩", "chess_pawn": "♟️",
        "video_game": "🎮", "soccer": "⚽", "basketball": "🏀", "football": "🏈", "tennis": "🎾",
        "tada": "🎉", "confetti_ball": "🎊", "balloon": "🎈", "gift": "🎁", "ribbon": "🎀",
        "birthday": "🎂", "christmas_tree": "🎄", "jack_o_lantern": "🎃", "fireworks": "🎆",
        "sparkler": "🎇", "art": "🎨", "performing_arts": "🎭", "ticket": "🎫", "clapper": "🎬",
        "microphone": "🎤", "headphones": "🎧", "musical_note": "🎵", "notes": "🎶", "guitar": "🎸",
        "musical_keyboard": "🎹", "trumpet": "🎺", "violin": "🎻", "drum": "🥁",
        // Objects and work
        "rocket": "🚀", "airplane": "✈️", "car": "🚗", "red_car": "🚗", "taxi": "🚕", "bus": "🚌",
        "ambulance": "🚑", "fire_engine": "🚒", "police_car": "🚓", "truck": "🚚", "bike": "🚲",
        "ship": "🚢", "boat": "⛵", "sailboat": "⛵", "train": "🚋", "station": "🚉", "rotating_light": "🚨",
        "construction": "🚧", "vertical_traffic_light": "🚦", "fuelpump": "⛽", "anchor": "⚓",
        "house": "🏠", "house_with_garden": "🏡", "office": "🏢", "hospital": "🏥", "bank": "🏦",
        "hotel": "🏨", "school": "🏫", "factory": "🏭", "castle": "🏰", "tent": "⛺", "mountain": "⛰️",
        "camping": "🏕️", "beach_umbrella": "🏖️", "desert_island": "🏝️", "statue_of_liberty": "🗽",
        "watch": "⌚", "iphone": "📱", "calling": "📲", "computer": "💻", "keyboard": "⌨️",
        "desktop_computer": "🖥️", "printer": "🖨️", "computer_mouse": "🖱️", "trackball": "🖲️",
        "minidisc": "💽", "floppy_disk": "💾", "cd": "💿", "dvd": "📀", "camera": "📷",
        "camera_flash": "📸", "video_camera": "📹", "movie_camera": "🎥", "film_projector": "📽️",
        "tv": "📺", "radio": "📻", "telephone": "☎️", "phone": "☎️", "telephone_receiver": "📞",
        "pager": "📟", "fax": "📠", "battery": "🔋", "electric_plug": "🔌", "bulb": "💡",
        "flashlight": "🔦", "candle": "🕯️", "moneybag": "💰", "dollar": "💵", "euro": "💶",
        "pound": "💷", "yen": "💴", "credit_card": "💳", "gem": "💎", "money_with_wings": "💸",
        "chart": "💹", "chart_with_upwards_trend": "📈", "chart_with_downwards_trend": "📉",
        "bar_chart": "📊", "email": "📧", "e-mail": "📧", "envelope": "✉️", "incoming_envelope": "📨",
        "envelope_with_arrow": "📩", "outbox_tray": "📤", "inbox_tray": "📥", "package": "📦",
        "mailbox": "📫", "mailbox_closed": "📪", "postbox": "📮", "pencil2": "✏️", "black_nib": "✒️",
        "pen": "🖊️", "paintbrush": "🖌️", "crayon": "🖍️", "memo": "📝", "pencil": "📝",
        "briefcase": "💼", "file_folder": "📁", "open_file_folder": "📂", "card_index_dividers": "🗂️",
        "date": "📅", "calendar": "📆", "spiral_notepad": "🗒️", "spiral_calendar": "🗓️",
        "card_index": "📇", "clipboard": "📋", "pushpin": "📌", "round_pushpin": "📍",
        "paperclip": "📎", "paperclips": "🖇️", "straight_ruler": "📏", "triangular_ruler": "📐",
        "scissors": "✂️", "card_file_box": "🗃️", "file_cabinet": "🗄️", "wastebasket": "🗑️",
        "lock": "🔒", "unlock": "🔓", "lock_with_ink_pen": "🔏", "closed_lock_with_key": "🔐",
        "key": "🔑", "old_key": "🗝️", "hammer": "🔨", "axe": "🪓", "pick": "⛏️",
        "hammer_and_wrench": "🛠️", "dagger": "🗡️", "crossed_swords": "⚔️", "gun": "🔫", "shield": "🛡️",
        "wrench": "🔧", "nut_and_bolt": "🔩", "gear": "⚙️", "clamp": "🗜️", "balance_scale": "⚖️",
        "link": "🔗", "chains": "⛓️", "toolbox": "🧰", "magnet": "🧲", "alembic": "⚗️",
        "test_tube": "🧪", "petri_dish": "🧫", "dna": "🧬", "microscope": "🔬", "telescope": "🔭",
        "satellite": "📡", "syringe": "💉", "pill": "💊", "door": "🚪", "bed": "🛏️", "toilet": "🚽",
        "shower": "🚿", "bathtub": "🛁", "soap": "🧼", "broom": "🧹", "basket": "🧺", "shopping_cart": "🛒",
        "smoking": "🚬", "moyai": "🗿", "hourglass": "⌛", "hourglass_flowing_sand": "⏳",
        "alarm_clock": "⏰", "stopwatch": "⏱️", "timer_clock": "⏲️", "clock": "🕰️", "mag": "🔍",
        "mag_right": "🔎", "book": "📖", "open_book": "📖", "books": "📚", "notebook": "📓",
        "ledger": "📒", "page_facing_up": "📄", "page_with_curl": "📃", "scroll": "📜",
        "newspaper": "📰", "bookmark_tabs": "📑", "bookmark": "🔖", "label": "🏷️", "bell": "🔔",
        "no_bell": "🔕", "loudspeaker": "📢", "mega": "📣", "speaker": "🔈", "mute": "🔇",
        "sound": "🔉", "loud_sound": "🔊", "triangular_flag_on_post": "🚩", "checkered_flag": "🏁",
        "white_flag": "🏳️", "black_flag": "🏴", "rainbow_flag": "🏳️‍🌈", "pirate_flag": "🏴‍☠️",
        "hu": "🇭🇺", "us": "🇺🇸", "gb": "🇬🇧", "uk": "🇬🇧", "de": "🇩🇪", "fr": "🇫🇷", "eu": "🇪🇺",
        "jp": "🇯🇵", "it": "🇮🇹", "es": "🇪🇸", "at": "🇦🇹", "ro": "🇷🇴", "sk": "🇸🇰",
        "bug": "🐛", "ant": "🐜", "bee": "🐝", "honeybee": "🐝", "beetle": "🪲", "lady_beetle": "🐞",
        "spider": "🕷️", "snail": "🐌", "butterfly": "🦋", "snake": "🐍", "turtle": "🐢", "lizard": "🦎",
        "dragon": "🐉", "t-rex": "🦖", "whale": "🐳", "dolphin": "🐬", "fish": "🐟", "octopus": "🐙",
        "crab": "🦀", "shark": "🦈", "penguin": "🐧", "bird": "🐦", "chicken": "🐔", "eagle": "🦅",
        "owl": "🦉", "duck": "🦆", "frog": "🐸", "monkey": "🐒", "monkey_face": "🐵", "dog": "🐶",
        "dog2": "🐕", "cat": "🐱", "cat2": "🐈", "mouse": "🐭", "hamster": "🐹", "rabbit": "🐰",
        "fox_face": "🦊", "bear": "🐻", "panda_face": "🐼", "koala": "🐨", "tiger": "🐯", "lion": "🦁",
        "cow": "🐮", "pig": "🐷", "horse": "🐴", "unicorn": "🦄", "zebra": "🦓", "elephant": "🐘",
        "camel": "🐫", "giraffe": "🦒", "sheep": "🐑", "goat": "🐐", "llama": "🦙", "sloth": "🦥",
        "otter": "🦦", "hedgehog": "🦔", "bat": "🦇", "paw_prints": "🐾", "feet": "🐾",
        "seedling": "🌱", "herb": "🌿", "shamrock": "☘️", "four_leaf_clover": "🍀", "evergreen_tree": "🌲",
        "deciduous_tree": "🌳", "palm_tree": "🌴", "cactus": "🌵", "tulip": "🌷", "rose": "🌹",
        "sunflower": "🌻", "blossom": "🌼", "cherry_blossom": "🌸", "hibiscus": "🌺", "bouquet": "💐",
        "maple_leaf": "🍁", "fallen_leaf": "🍂", "leaves": "🍃", "mushroom": "🍄", "chestnut": "🌰",
        "apple": "🍎", "green_apple": "🍏", "pear": "🍐", "tangerine": "🍊", "orange": "🍊", "lemon": "🍋",
        "banana": "🍌", "watermelon": "🍉", "grapes": "🍇", "strawberry": "🍓", "melon": "🍈",
        "cherries": "🍒", "peach": "🍑", "mango": "🥭", "pineapple": "🍍", "coconut": "🥥", "kiwi_fruit": "🥝",
        "tomato": "🍅", "eggplant": "🍆", "avocado": "🥑", "broccoli": "🥦", "carrot": "🥕", "corn": "🌽",
        "hot_pepper": "🌶️", "cucumber": "🥒", "potato": "🥔", "bread": "🍞", "croissant": "🥐",
        "cheese": "🧀", "egg": "🥚", "fried_egg": "🍳", "bacon": "🥓", "hamburger": "🍔", "fries": "🍟",
        "pizza": "🍕", "hotdog": "🌭", "sandwich": "🥪", "taco": "🌮", "burrito": "🌯", "salad": "🥗",
        "spaghetti": "🍝", "ramen": "🍜", "stew": "🍲", "sushi": "🍣", "bento": "🍱", "rice": "🍚",
        "curry": "🍛", "icecream": "🍦", "ice_cream": "🍨", "doughnut": "🍩", "cookie": "🍪", "cake": "🍰",
        "cupcake": "🧁", "pie": "🥧", "chocolate_bar": "🍫", "candy": "🍬", "lollipop": "🍭",
        "honey_pot": "🍯", "coffee": "☕", "tea": "🍵", "beer": "🍺", "beers": "🍻", "wine_glass": "🍷",
        "cocktail": "🍸", "tropical_drink": "🍹", "champagne": "🍾", "clinking_glasses": "🥂",
        "tumbler_glass": "🥃", "cup_with_straw": "🥤", "milk_glass": "🥛", "baby_bottle": "🍼",
        "fork_and_knife": "🍴", "plate_with_cutlery": "🍽️", "spoon": "🥄",
        "crown": "👑", "eyeglasses": "👓", "dark_sunglasses": "🕶️", "necktie": "👔", "shirt": "👕",
        "tshirt": "👕", "jeans": "👖", "dress": "👗", "lipstick": "💄", "ring": "💍", "handbag": "👜",
        "school_satchel": "🎒", "mans_shoe": "👞", "athletic_shoe": "👟", "high_heel": "👠", "tophat": "🎩",
        "mortar_board": "🎓", "billed_cap": "🧢", "umbrella_with_rain_drops": "☔",
        "atom_symbol": "⚛️", "yin_yang": "☯️", "peace_symbol": "☮️", "zodiac": "♈",
        "mens": "🚹", "womens": "🚺", "restroom": "🚻", "wheelchair": "♿", "parking": "🅿️",
        "atm": "🏧", "potable_water": "🚰", "no_smoking": "🚭", "children_crossing": "🚸",
        "beginner": "🔰", "trident": "🔱", "fleur_de_lis": "⚜️", "name_badge": "📛",
        "o": "⭕", "o2": "🅾️", "a": "🅰️", "b": "🅱️", "ab": "🆎", "cl": "🆑", "id": "🆔", "vs": "🆚",
        "white_flower": "💮", "ideograph_advantage": "🉐", "accept": "🉑", "secret": "㊙️",
        "congratulations": "㊗️", "u5272": "🈹", "u7121": "🈚", "koko": "🈁", "sa": "🈂️",
    ]

    /// Every emoji by its Unicode name in snake case, built on first use.
    private static let unicodeNames: [String: String] = {
        var result: [String: String] = [:]
        let ranges: [ClosedRange<UInt32>] = [0x2190...0x21FF, 0x2300...0x23FF, 0x2460...0x24FF, 0x25A0...0x27BF,
                                             0x2900...0x297F, 0x2B00...0x2BFF, 0x1F000...0x1FAFF]
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value), scalar.properties.isEmoji,
                      let name = scalar.properties.name else { continue }
                var key = ""
                for ch in name.lowercased() {
                    if ch.isLetter || ch.isNumber { key.append(ch) } else if !key.hasSuffix("_") { key.append("_") }
                }
                while key.hasSuffix("_") { key.removeLast() }
                guard !key.isEmpty, result[key] == nil else { continue }
                var emoji = String(scalar)
                // Text-default emoji get the emoji presentation selector.
                if !scalar.properties.isEmojiPresentation { emoji.unicodeScalars.append("\u{FE0F}") }
                result[key] = emoji
            }
        }
        return result
    }()
}
