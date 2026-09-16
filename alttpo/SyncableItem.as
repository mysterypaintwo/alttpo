
interface SRAMReader {
  uint8  read_u8 (uint16 offs);
  uint16 read_u16(uint16 offs);
}

interface SRAMWriter {
  void write_u8(uint16 offs, uint8 value);
  void write_u16(uint16 offs, uint16 value);
}

interface SRAM : SRAMReader, SRAMWriter {}

class SRAMArray : SRAM {
  array<uint8>@ sram;

  SRAMArray(array<uint8>@ sram) {
    @this.sram = @sram;
  }

  uint8  read_u8 (uint16 offs) {
    return sram[offs];
  }
  uint16 read_u16(uint16 offs) {
    return uint16(sram[offs]) | (uint16(sram[offs+1]) << 8);
  }
  void write_u8 (uint16 offs, uint8 value) {
    sram[offs] = value;
  }
  void write_u16(uint16 offs, uint16 value) {
    write_u8(offs+0, uint8(value));
    write_u8(offs+1, uint8(value >> 8));
  }
}

funcdef uint16 ItemMutate(SRAM@ localSRAM, uint16 oldValue, uint16 newValue);

funcdef void NotifyItemReceived(const string &in name);
funcdef void NotifyNewItems(uint16 oldValue, uint16 newValue, NotifyItemReceived @notify);
funcdef bool CanWriteItem(uint16 offs);

SyncableItem@ whenSyncItems(SyncableItem@ item) {
  @item.canWriteItem = function(uint16 offs) {
    if (settings is null) {
      return true;
    }
    return settings.SyncItems;
  };
  return item;
}

SyncableItem@ whenSyncDungeonItems(SyncableItem@ item) {
  @item.canWriteItem = function(uint16 offs) {
    if (settings is null) {
      return true;
    }
    return settings.SyncDungeonItems;
  };
  return item;
}

SyncableItem@ whenSyncPendants(SyncableItem@ item) {
  @item.canWriteItem = function(uint16 offs) {
    if (settings is null) {
      return true;
    }
    return settings.SyncPendants;
  };
  return item;
}

SyncableItem@ whenSyncCrystals(SyncableItem@ item) {
  @item.canWriteItem = function(uint16 offs) {
    if (settings is null) {
      return true;
    }
    return settings.SyncCrystals;
  };
  return item;
}

SyncableItem@ whenSyncProgress(SyncableItem@ item) {
  @item.canWriteItem = function(uint16 offs) {
    if (settings is null) {
      return true;
    }
    return settings.SyncProgress;
  };
  return item;
}

// list of SRAM values to sync as items:
class SyncableItem {
  uint16  offs;   // SRAM offset from $7EF000 base address
  uint8   size;   // 1 - byte, 2 - word
  uint8   type;   // 0 - custom mutate, 1 - highest wins, 2 - bitfield, 3+ TBD...
  bool is_sm;       // whether the syncable is a super metroid item
  ItemMutate @mutate = null;
  NotifyNewItems @notifyNewItems = null;
  CanWriteItem @canWriteItem = null;

  SyncableItem(uint16 offs, uint8 size, uint8 type, NotifyNewItems @notifyNewItems = null, bool is_sm = false) {
    this.offs = offs;
    this.size = size;
    this.type = type;
    this.is_sm = is_sm;
    @this.notifyNewItems = notifyNewItems;
  }

  SyncableItem(uint16 offs, uint8 size, ItemMutate @mutate, NotifyNewItems @notifyNewItems = null, bool is_sm = false) {
    this.offs = offs;
    this.size = size;
    this.type = 0;
    this.is_sm = is_sm;
    @this.mutate = mutate;
    @this.notifyNewItems = notifyNewItems;
  }

  uint16 oldValue;
  uint16 newValue;
  void start(SRAMReader@ localSRAM) {
    oldValue = read(localSRAM);
    newValue = oldValue;
  }

  void apply(SRAM@ localSRAM, SRAMReader@ remoteSRAM) {
    auto remoteValue = read(remoteSRAM);
    newValue = modify(localSRAM, newValue, remoteValue);
  }

  bool finish(SRAM@ localSRAM, NotifyItemReceived @notifyItemReceived = null) {
    if (canWriteItem !is null) {
      if (!canWriteItem(offs)) {
        return false;
      }
    }

    if (newValue == oldValue) {
      return false;
    }
    
    if ((notifyNewItems !is null) && (notifyItemReceived !is null)) {
      notifyNewItems(oldValue, newValue, notifyItemReceived);
    }

    write(localSRAM, newValue);
    if (is_sm) update_sm_counts();
    return true;
  }

  uint16 modify(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
    if (type == 0) {
      if (@this.mutate is null) {
        return oldValue;
      }
      return this.mutate(localSRAM, oldValue, newValue);
    } else if (type == 1) {
      // max value:
      if (newValue > oldValue) {
        return newValue;
      }
      return oldValue;
    } else if (type == 2) {
      // bitfield OR:
      newValue = oldValue | newValue;
      return newValue;
    }
    return oldValue;
  }

  uint16 read(SRAMReader@ remoteSRAM) {
    if (size == 1) {
      return remoteSRAM.read_u8(offs);
    } else {
      return remoteSRAM.read_u16(offs);
    }
  }

  void write(SRAM@ localSRAM, uint16 newValue) {
    if (size == 1) {
      localSRAM.write_u8(offs, uint8(newValue));
    } else if (size == 2) {
      localSRAM.write_u16(offs, newValue);
    }
  }

  void update_sm_counts() {
    int base = 0;
    if (local.get_in_sm()) {
      base = 0x7E09A2;
    } else {
      base = 0xA17900;
    }
    uint8 eold;
    uint8 enew;
    uint8 old_count;
    // NOTE: must be uint16, not uint8: energy/reserve capacity diffs can exceed 255
    // (e.g. joining a player who already has multiple E-Tanks/Reserve tanks synced in
    // at once), and a uint8 here would silently wrap around, producing bogus notification
    // text like "Got 0 Reserve Tanks" instead of the real count.
    uint16 diff;
    switch (offs) {
      case 0x02:
        eold = bus::read_u8(base + offs - 2);
        bus::write_u8( base + offs - 2, (newValue ^ oldValue) | eold);
        break;
      case 0x03:
        eold = bus::read_u8(base + offs - 2);
        if ((newValue ^ oldValue) & 0x40 == 0x40){
          bus::write_u16(0x7ec630, 0x3438);
          bus::write_u16(0x7ec632, 0x7438);
          bus::write_u16(0x7ec670, 0x3439);
          bus::write_u16(0x7ec672, 0x7439);
        }
        if ((newValue ^ oldValue) & 0x80 == 0x80){
          bus::write_u16(0x7ec636, 0x343a);
          bus::write_u16(0x7ec638, 0x743a);
          bus::write_u16(0x7ec676, 0x343b);
          bus::write_u16(0x7ec678, 0x743b);
        }
        bus::write_u8( base + offs - 2, (newValue ^ oldValue) | eold);
        break;
      case 0x06:
        //special crap here to avoid the murder beam
        eold = bus::read_u8(base + offs - 2);
        enew = (newValue ^ oldValue) | eold;
        if(enew & 0x08 == 0x08) enew = enew & 0xFB;
        bus::write_u8( base + offs - 2, enew) ;
        break;
      case 0x07:
        eold = bus::read_u8(base + offs - 2);
        enew = (newValue ^ oldValue) | eold;
        bus::write_u8(base + offs - 2, enew);
        local.notify("Got Charge Beam");
        break;
      case 0x26:
        old_count = bus::read_u8(base + offs - 2);
        diff = newValue - oldValue;
        bus::write_u8(base + offs - 2, old_count + diff);
        // X-Fusion: the per-location tank flags in mxfFlagNotes already notify for
        // this pickup with its real location (see notify_mxf_flags() in
        // LocalGameState.as); notifying here too would just duplicate it.
        if (!rom.is_mxf()) local.notify("Got " + fmtInt(diff) + " Missiles");
        break;
      case 0x2a:
        old_count = bus::read_u8(base + offs - 2);
        diff = newValue - oldValue;
        bus::write_u8(base + offs - 2, old_count + diff);
        if (!rom.is_mxf()) local.notify("Got " + fmtInt(diff) + " Super Missiles");
        break;
      case 0x2e:
        old_count = bus::read_u8(base + offs - 2);
        diff = newValue - oldValue;
        bus::write_u8(base + offs - 2, old_count + diff);
        if (!rom.is_mxf()) local.notify("Got " + fmtInt(diff) + " Power Bombs");
        break;
      case 0x22:
        bus::write_u16(base + offs - 2, bus::read_u16(base + offs));
        // X-Fusion: the per-location tank flags in mxfFlagNotes already notify for
        // this pickup with its real location (see notify_mxf_flags() in
        // LocalGameState.as); notifying here too would just duplicate it.
        if (!rom.is_mxf()) {
          diff = newValue - oldValue;
          if (diff/100 == 1) local.notify("Got " + fmtInt(diff/100) + " Energy Tank");
          else local.notify("Got " + fmtInt(diff/100) + " Energy Tanks");
        }
        break;
       case 0x32:
        // X-Fusion's Reserve-X tanks don't fill immediately on pickup -- capacity
        // ramps up gradually as it "charges", so diff here is rarely a clean multiple
        // of 100 and this notify would routinely fire as "Got 0 Reserve-X" while that
        // charge (or a synced partial-charge merge from another player) is in
        // progress. The per-location Reserve-X flags in mxfFlagNotes (see
        // notify_mxf_flags() in LocalGameState.as) notify reliably instead, once per
        // actual pickup, with the real randomized item and location.
        if (!rom.is_mxf()) {
          diff = newValue - oldValue;
          if (diff/100 == 1) local.notify("Got " + fmtInt(diff/100) + " Reserve Tank");
          else local.notify("Got " + fmtInt(diff/100) + " Reserve Tanks");
        }
        break;
      default: return;
    }
  }
}

class SyncableHealthCapacity : SyncableItem {
  SyncableHealthCapacity() {
    super(0x36C, 1, 0);

    // this custom SyncableItem covers both:
    // SyncableItem(0x36B, 1, 1),  // heart pieces (out of four)
    // SyncableItem(0x36C, 1, 1),  // health capacity
  }

  uint16 modify(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) override {
    // max value:
    if (newValue > oldValue) {
      return newValue;
    }
    return oldValue;
  }

  bool finish(SRAM@ localSRAM, NotifyItemReceived @notifyItemReceived = null) override {
    // Disable hearts sync based on setting:
    if (settings !is null) {
      if (!settings.SyncHearts) {
        return false;
      }
    }

    if (newValue <= oldValue) {
      return false;
    }

    if (notifyItemReceived !is null) {
      auto oldHearts = uint8(oldValue) & ~uint8(7);
      auto oldPieces = uint8(oldValue) & uint8(3);
      auto newHearts = uint8(newValue) & ~uint8(7);
      auto newPieces = uint8(newValue) & uint8(3);

      auto diffHearts = (newHearts + (newPieces << 1)) - (oldHearts + (oldPieces << 1));
      auto fullHearts = diffHearts >> 3;
      auto pieces = (diffHearts & 7) >> 1;

      string hc;
      if (fullHearts == 1) {
        hc = "1 new heart";
      } else if (fullHearts > 1) {
        hc = fmtInt(fullHearts) + " new hearts";
      }
      if (fullHearts >= 1 && pieces >= 1) hc += ", ";

      if (pieces == 1) {
        hc += "1 new heart piece";
      } else if (pieces > 0) {
        hc += fmtInt(pieces) + " new heart pieces";
      }

      notifyItemReceived(hc);
    }

    write(localSRAM, newValue);

    return true;
  }

  uint16 read(SRAMReader@ remoteSRAM) override {
    // this works because [0x36C] is always a multiple of 8 and the lower 3 bits are always zero
    // and [0x36B] is in the range [0..3] aka 2 bits:
    return (remoteSRAM.read_u8(0x36C) & ~7) | (remoteSRAM.read_u8(0x36B) & 3);
  }

  void write(SRAM@ localSRAM, uint16 newValue) override {
    // split out the full hearts from the heart pieces:
    auto hearts = uint8(newValue) & ~uint8(7);
    auto pieces = uint8(newValue) & uint8(3);
    //message("heart write! " + fmtHex(uint8(oldValue),2) + " -> " + fmtHex(uint8(newValue),2) + " = " + fmtInt(hearts) + ", " + fmtInt(pieces));
    localSRAM.write_u8(0x36C, hearts);
    localSRAM.write_u8(0x36B, pieces);
  }
}

class SyncableUnderworldRoom {
  uint16 _room, _offs;
  uint16 room {
    get { return _room; }
    set {
      _room = value;
      _offs = value << 1;
    }
  }
  uint16 mask;

  SyncableUnderworldRoom(uint16 room, uint16 mask) {
    this.room = room;
    this.mask = mask;
  }

  // temporary state:
  uint16 oldValue;
  uint16 newValue;

  void start(SRAMReader@ localSRAM) {
    oldValue = localSRAM.read_u16(_offs);
    newValue = oldValue;
  }

  void apply(SRAM@ localSRAM, SRAMReader@ remoteSRAM) {
    auto remoteValue = remoteSRAM.read_u16(_offs);
    // mask off new bits we don't care about:
    remoteValue &= mask;
    newValue = localSRAM.read_u16(_offs) | remoteValue;
  }

  bool finish(SRAM@ localSRAM, NotifyItemReceived @notifyItemReceived = null) {
    if (newValue == oldValue) {
      return false;
    }

    //if ((notifyNewItems !is null) && (notifyItemReceived !is null)) {
    //  notifyNewItems(oldValue, newValue, notifyItemReceived);
    //}

    localSRAM.write_u16(_offs, newValue);

    //if (local.is_in_dungeon_location() && (local.dungeon_room == _room)) {
    //  // update WRAM copies of door state:
    //  bus::write_u16(0x7E0400, newValue);
    //  bus::write_u16(0x7E068C, newValue | 0x0F00);
    //  bus::write_u16(0x7E0402, (newValue & 0x0FF0) << 4);
    //  bus::write_u16(0x7E0408, (newValue & 0x000F));
    //}

    return true;
  }
}

// 0x3C5
uint16 mutateWorldState(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  // if local player is in the intro sequence, keep them there:
  //if (oldValue < 2) return oldValue;

  if (rom.is_alttp()) {
    // moving from rain state to non-rain state:
    if (newValue >= 2 && oldValue < 2) {
      // this game function loads sprite graphics:
      pb.jsl(rom.fn_sprite_load_gfx_properties);

      // if in overworld:
      if (local.module == 0x09 && local.sub_module == 0x00) {
        // disable subscreen:
        bus::write_u8(0x7E001D, 0x00);
        // remove rain overlay:
        bus::write_u8(0x7E008C, 0x00);
        // this game function loads the new song list
        pb.jsl(rom.fn_overworld_finish_mirror_warp);

        // set ambient sfx to silence:
        pb.lda_immed(0x05);
        pb.sta_bank(0x012D);
      }
    }
  }

  // sync the bigger value:
  if (newValue > oldValue) return newValue;
  return oldValue;
}

// 0x3C6
uint16 mutateProgress1(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  if (rom.is_alttp()) {
    // uncle leaving link's house for the first time will add the telepathic follower.
    // if receiving uncle's gear, remove zelda telepathic follower:
    if ((newValue & 0x01) == 0x01) {
      auto follower = localSRAM.read_u8(0x3CC);
      if (follower == 0x05) {
        localSRAM.write_u8(0x3CC, 0x00);
      }
    }
  }

  // if local player has not achieved uncle leaving house, leave it cleared otherwise link never wakes up:
  if ((oldValue & 0x10) == 0) {
    newValue &= ~uint8(0x10);
  }
  return newValue | oldValue;
}

// 0x3C9
uint16 mutateProgress2(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  // lose smithy follower if already rescued:
  if ((newValue & 0x20) == 0x20) {
    auto follower = localSRAM.read_u8(0x3CC);
    if (follower == 0x07 || follower == 0x08) {
      localSRAM.write_u8(0x3CC, 0x00);
    }
  }

  // remove purple chest follower if purple chest opened:
  if ((newValue & 0x10) == 0x10) {
    auto follower = localSRAM.read_u8(0x3CC);
    if (follower == 0x0C) {
      localSRAM.write_u8(0x3CC, 0x00);
    }
  }

  return newValue | oldValue;
}

uint16 mutateSword(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  // during the dwarven swordsmith quest, sword goes to 0xFF when taken away, so avoid that trap:
  if (newValue >= 1 && newValue <= 4 && newValue > oldValue) {
    if (rom.is_alttp()) {
      // JSL DecompSwordGfx
      pb.jsl(rom.fn_decomp_sword_gfx);
      pb.jsl(rom.fn_sword_palette);
      local.lttp_uniqtile_clear_sword();
    }
    return newValue;
  }
  return oldValue;
}

uint16 mutateShield(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  //if(local.gotShield == 0)
  //{
  //  local.gotShield = newValue;
  //}
  //if (newValue > oldValue && newValue > local.gotShield) {
  if (newValue > oldValue) { 
    if (rom.is_alttp()) {
      // JSL DecompShieldGfx
      pb.jsl(rom.fn_decomp_shield_gfx);
      pb.jsl(rom.fn_shield_palette);
      local.lttp_uniqtile_clear_shield();
    }
    //local.gotShield = newValue;
    return newValue;
  }
  return oldValue;
}

// NOTE: this is called for both gloves and armor separately so could JSL twice in succession for one frame.
uint16 mutateArmorGloves(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  if (newValue > oldValue) {
    if (rom.is_alttp()) {
      // JSL Palette_ChangeGloveColor
      pb.jsl(rom.fn_armor_glove_palette);
    }
    return newValue;
  }
  return oldValue;
}

uint16 mutateBottleItem(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  // only sync gaining a new bottle: 0 = no bottle, 2 = empty bottle.
  if (oldValue == 0 && newValue != 0) return newValue;
  return oldValue;
}

uint16 mutateZeroToNonZero(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  // Allow if replacing 'no item':
  if (oldValue == 0 && newValue != 0) return newValue;
  return oldValue;
}

// X-Fusion (mxf): hard ceilings on synced capacities, so a bad merge (e.g. a
// duplicated pickup, or a remote whose own state has somehow gone out of bounds) can
// never push a local capacity past what's actually obtainable in-game. Used only by
// MetroidXFusionMapping.update_syncables() in ROMMapping.as -- vanilla SM/SMZ3 have
// different (unmodified) capacity limits and aren't affected by these.
const uint16 MxfMaxMissileCapacity    = 99;
const uint16 MxfMaxPowerBombCapacity  = 50;

const uint16 MxfBaseEnergyCapacity    = 99;  // starting energy capacity with zero E-Tanks
const uint16 MxfEnergyPerETank        = 100;
const uint16 MxfMaxETanks             = 14;
const uint16 MxfMaxEnergyCapacity     = MxfBaseEnergyCapacity + MxfMaxETanks * MxfEnergyPerETank;

const uint16 MxfEnergyPerReserveTank  = 100;
const uint16 MxfMaxReserveTanks       = 7;
const uint16 MxfMaxReserveCapacity    = MxfMaxReserveTanks * MxfEnergyPerReserveTank;

// takes the higher of old/new (same as the "highest wins" merge type), then clamps to
// cap. Never returns less than oldValue, even if oldValue is already above cap (from
// state that predates this cap), so we only ever refuse to grant *more* than the cap
// allows -- we don't claw back anything the player already legitimately has.
uint16 mutateMxfCappedHighest(uint16 oldValue, uint16 newValue, uint16 cap) {
  uint16 v = (newValue > oldValue) ? newValue : oldValue;
  if (v > cap) v = cap;
  if (v < oldValue) v = oldValue;
  return v;
}

uint16 mutateMxfMissileCapacity(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  return mutateMxfCappedHighest(oldValue, newValue, MxfMaxMissileCapacity);
}

uint16 mutateMxfPowerBombCapacity(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  return mutateMxfCappedHighest(oldValue, newValue, MxfMaxPowerBombCapacity);
}

uint16 mutateMxfEnergyCapacity(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  return mutateMxfCappedHighest(oldValue, newValue, MxfMaxEnergyCapacity);
}

uint16 mutateMxfReserveCapacity(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  return mutateMxfCappedHighest(oldValue, newValue, MxfMaxReserveCapacity);
}

uint16 mutateFlute(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  // Allow if replacing 'no item':
  if (oldValue == 0 && newValue != 0) return newValue;
  // Allow if replacing 'flute' with 'bird+flute':
  if (oldValue == 2 && newValue == 3) return newValue;
  return oldValue;
}

const uint8 bitPowder   = 1<<4;
const uint8 bitMushroom = 1<<5;

uint16 mutateRandomizerItems(SRAM@ localSRAM, uint16 oldValue, uint16 newValue) {
  // INVENTORY_SWAP = "$7EF38C"
  // Item Tracking Slot
  // brmpnskf
  // b = blue boomerang
  // r = red boomerang
  // m = mushroom current
  // p = magic powder
  // n = mushroom past
  // s = shovel
  // k = fake flute
  // f = working flute

  uint8 mushroom = localSRAM.read_u8(0x344);
  // if gaining powder and have no inventory:
  if (
    ((oldValue & bitPowder) == 0) &&
    ((newValue & bitPowder) == bitPowder) &&
    mushroom == 0
  ) {
    // set powder in inventory:
    localSRAM.write_u8(0x344, 2);
  }

  // if gaining mushroom and have no inventory:
  if (
    ((oldValue & bitMushroom) == 0) &&
    ((newValue & bitMushroom) == bitMushroom) &&
    mushroom == 0
  ) {
    // set mushroom in inventory:
    localSRAM.write_u8(0x344, 1);
  }

  //// if had mushroom and lost mushroom:
  //if (
  //  ((oldValue & bitMushroom) == bitMushroom) &&
  //  ((newValue & bitMushroom) == 0) &&
  //  mushroom == 1
  //) {
  //  // if don't have powder, set to empty:
  //  if ((oldValue & bitPowder) == 0) {
  //    localSRAM.write_u8(0x344, 0);
  //  } else {
  //    // else set powder in inventory:
  //    localSRAM.write_u8(0x344, 2);
  //  }
  //}

  return oldValue | newValue;
}

void notifySingleItem(const array<string> @names, NotifyItemReceived @notify, uint16 new) {
  if (new == 0) return;

  new--;
  if (new >= names.length()) return;

  notify(names[new]);
}

const array<string> @bowNames         = {"Bow", "Bow", "Silver Bow", "Silver Bow"};
const array<string> @boomerangNames   = {"Blue Boomerang", "Red Boomerang"};
const array<string> @hookshotNames    = {"Hookshot"};
const array<string> @mushroomNames    = {"Mushroom", "Magic Powder"};
const array<string> @firerodNames     = {"Fire Rod"};
const array<string> @icerodNames      = {"Ice Rod"};
const array<string> @bombosNames      = {"Bombos Medallion"};
const array<string> @etherNames       = {"Ether Medallion"};
const array<string> @quakeNames       = {"Quake Medallion"};
const array<string> @lampNames        = {"Lamp"};
const array<string> @hammerNames      = {"Hammer"};
const array<string> @fluteNames       = {"Shovel", "Flute", "Flute (activated)"};
const array<string> @bugnetNames      = {"Bug Catching Net"};
const array<string> @bookNames        = {"Book of Mudora"};
const array<string> @canesomariaNames = {"Cane of Somaria"};
const array<string> @canebyrnaNames   = {"Cane of Byrna"};
const array<string> @magiccapeNames   = {"Magic Cape"};
const array<string> @magicmirrorNames = {"Magic Scroll", "Magic Mirror"};
const array<string> @glovesNames      = {"Power Gloves", "Titan's Mitts"};
const array<string> @bootsNames       = {"Pegasus Boots"};
const array<string> @flippersNames    = {"Flippers"};
const array<string> @moonpearlNames   = {"Moon Pearl"};
const array<string> @coatNames        = {"Coat"};
const array<string> @swordNames       = {"Fighter Sword", "Master Sword", "Tempered Sword", "Golden Sword"};
const array<string> @shieldNames      = {"Blue Shield", "Red Shield", "Mirror Shield"};
const array<string> @armorNames       = {"Blue Mail", "Red Mail"};
const array<string> @bottleNames      = {"", "Empty Bottle", "Red Potion", "Green Potion", "Blue Potion", "Fairy", "Bee", "Good Bee"};
const array<string> @magicNames       = {"1/2 Magic", "1/4 Magic"};
const array<string> @worldStateNames  = {"Q#Hyrule Castle Dungeon started", "Q#Hyrule Castle Dungeon completed", "Q#Search for Crystals started"};

void nameForBow        (uint16 old, uint16 new, NotifyItemReceived @notify) {
  // 0x01 - normal bow with no arrows
  // 0x02 - normal bow with arrows
  // 0x03 - silver bow with no silver arrows
  // 0x04 - silver bow with silver arrows
  if (old == 1 && new == 2) return;
  if (old == 2 && new == 1) return;
  if (old == 3 && new == 4) return;
  if (old == 4 && new == 3) return;
  notifySingleItem(bowNames, notify, new);
}
void nameForBoomerang        (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(boomerangNames, notify, new); }
void nameForHookshot         (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(hookshotNames, notify, new); }
void nameForMushroom         (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(mushroomNames, notify, new); }
void nameForFirerod          (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(firerodNames, notify, new); }
void nameForIcerod           (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(icerodNames, notify, new); }
void nameForBombos           (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(bombosNames, notify, new); }
void nameForEther            (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(etherNames, notify, new); }
void nameForQuake            (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(quakeNames, notify, new); }
void nameForLamp             (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(lampNames, notify, new); }
void nameForHammer           (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(hammerNames, notify, new); }
void nameForFlute            (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(fluteNames, notify, new); }
void nameForBugnet           (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(bugnetNames, notify, new); }
void nameForBook             (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(bookNames, notify, new); }
void nameForCanesomaria      (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(canesomariaNames, notify, new); }
void nameForCanebyrna        (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(canebyrnaNames, notify, new); }
void nameForMagiccape        (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(magiccapeNames, notify, new); }
void nameForMagicmirror      (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(magicmirrorNames, notify, new); }
void nameForGloves           (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(glovesNames, notify, new); }
void nameForBoots            (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(bootsNames, notify, new); }
void nameForFlippers         (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(flippersNames, notify, new); }
void nameForMoonpearl        (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(moonpearlNames, notify, new); }
void nameForCoat             (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(coatNames, notify, new); }
void nameForSword            (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(swordNames, notify, new); }
void nameForShield           (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(shieldNames, notify, new); }
void nameForArmor            (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(armorNames, notify, new); }
void nameForBottle           (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(bottleNames, notify, new); }

void nameForMagic         (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(magicNames, notify, new); }
void nameForWorldState    (uint16 _, uint16 new, NotifyItemReceived @notify) { notifySingleItem(worldStateNames, notify, new); }
void nameForTriforcePieces(uint16 old, uint16 new, NotifyItemReceived @notify) {
  auto diff = new - old;
  if (diff == 1) {
    notify("1 new triforce piece");
  } else {
    notify(fmtInt(diff) + " new triforce pieces");
  }
}

void notifyBitfieldItem(const array<string> @names, NotifyItemReceived @notify, uint16 old, uint16 new) {
  if (new == 0) return;

  for (uint i = 0, k = 1; i < 8; i++, k <<= 1) {
    if ((old & k) == 0 && (new & k) == k) {
      notify(names[i]);
    }
  }
}

const array<string> @compass1Names = { "",
                                       "",
                                       "Ganon's Tower Compass",
                                       "Turtle Rock Compass",
                                       "Thieves Town Compass",
                                       "Tower of Hera Compass",
                                       "Ice Palace Compass",
                                       "Skull Woods Compass" };

const array<string> @compass2Names = { "Misery Mire Compass",
                                       "Dark Palace Compass",
                                       "Swamp Palace Compass",
                                       "Hyrule Castle 2 Compass",
                                       "Desert Palace Compass",
                                       "Eastern Palace Compass",
                                       "Hyrule Castle Compass",
                                       "Sewer Passage Compass" };

const array<string> @bigkey1Names  = { "",
                                       "",
                                       "Ganon's Tower Big Key",
                                       "Turtle Rock Big Key",
                                       "Thieves Town Big Key",
                                       "Tower of Hera Big Key",
                                       "Ice Palace Big Key",
                                       "Skull Woods Big Key" };

const array<string> @bigkey2Names  = { "Misery Mire Big Key",
                                       "Dark Palace Big Key",
                                       "Swamp Palace Big Key",
                                       "Hyrule Castle 2 Big Key",
                                       "Desert Palace Big Key",
                                       "Eastern Palace Big Key",
                                       "Hyrule Castle Big Key",
                                       "Sewer Passage Big Key" };

const array<string> @map1Names     = { "",
                                       "",
                                       "Ganon's Tower Map",
                                       "Turtle Rock Map",
                                       "Thieves Town Map",
                                       "Tower of Hera Map",
                                       "Ice Palace Map",
                                       "Skull Woods Map" };

const array<string> @map2Names     = { "Misery Mire Map",
                                       "Dark Palace Map",
                                       "Swamp Palace Map",
                                       "Hyrule Castle 2 Map",
                                       "Desert Palace Map",
                                       "Eastern Palace Map",
                                       "Hyrule Castle Map",
                                       "Sewer Passage Map" };

const array<string> @pendantsNames  = { "Red Pendant",
                                        "Blue Pendant",
                                        "Green Pendant",
                                        "",
                                        "",
                                        "",
                                        "",
                                        "" };

const array<string> @crystalsNames  = { "Crystal #6",
                                        "Crystal #1",
                                        "Crystal #5",
                                        "Crystal #7",
                                        "Crystal #2",
                                        "Crystal #4",
                                        "Crystal #3",
                                        "" };

const array<string> @progress1Names = { "Q#Uncle check completed",
                                        "Q#Priest's Wishes started",
                                        "Q#Zelda Rescue completed",
                                        "",
                                        "",
                                        "",
                                        "",
                                        "" };

const array<string> @progress2Names = { "Q#Hobo check completed",
                                        "Q#Bottle Salesman check completed",
                                        "",
                                        "Q#Flute Boy completed",
                                        "Q#Purple Chest completed",
                                        "Q#Smithy Rescue completed",
                                        "",
                                        "Q#Sword Tempering started" };

const array<string> @variable1Names = { "Varia Suit",
                                        "Spring Ball",
                                        "Morph Ball",
                                        "Screw Attack",
                                        "",
                                        "Gravity Suit",
                                        "",
                                        "" };

const array<string> @variable2Names = { "High Jump Boots",
                                        "Space Jump",
                                        "",
                                        "",
                                        "Bombs",
                                        "",
                                        "",
                                        "" };

const array<string> @variable3Names = { "Wave Beam",
                                        "Ice Beam",
                                        "Spazer",
                                        "Plasma",
                                        "",
                                        "",
                                        "",
                                        "" };

const array<string> @xfusionvariable1Names = {  "Varia Suit",
                                                "Super Missile",
                                                "Morph Ball",
                                                "Screw Attack",
                                                "Diffusion Missile",
                                                "Gravity Suit",
                                                "Blank2",
                                                "Spike Breaker" };

const array<string> @xfusionvariable2Names =  { "Super Jump",
                                                "Space Jump",
                                                "Blank4",
                                                "Lv.2 Speed Booster",
                                                "Bombs",
                                                "Lv.1 Speed Booster",
                                                "Grapple Beam",
                                                "Ice Missile" };

const array<string> @xfusionvariable3Names =  { "Wave Beam",
                                                "Ice Beam",
                                                "Wide Beam",
                                                "Plasma",
                                                "Blank9",
                                                "Blank10",
                                                "Blank11",
                                                "Blank12" };

void nameForCompass1 (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(compass1Names, notify, old, new); }
void nameForCompass2 (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(compass2Names, notify, old, new); }
void nameForBigkey1  (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(bigkey1Names, notify, old, new); }
void nameForBigkey2  (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(bigkey2Names, notify, old, new); }
void nameForMap1     (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(map1Names, notify, old, new); }
void nameForMap2     (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(map2Names, notify, old, new); }
void nameForPendants (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(pendantsNames, notify, old, new); }
void nameForCrystals (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(crystalsNames, notify, old, new); }
void nameForProgress1(uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(progress1Names, notify, old, new); }
void nameForProgress2(uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(progress2Names, notify, old, new); }

void nameForMetroidSuits (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(variable1Names, notify, old, new); }
void nameForMetroidBoots (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(variable2Names, notify, old, new); }
void nameForMetroidBeams (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(variable3Names, notify, old, new); }

void nameForXFusionSuits (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(xfusionvariable1Names, notify, old, new); }
void nameForXFusionBoots (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(xfusionvariable2Names, notify, old, new); }
void nameForXFusionBeams (uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(xfusionvariable3Names, notify, old, new); }

const array<string> @randomizerItems1Names = { "Flute (activated)",
                                               "Flute",
                                               "Shovel",
                                               "",
                                               "Magic Powder",
                                               "Mushroom",
                                               "Red Boomerang",
                                               "Blue Boomerang" };

const array<string> @randomizerItems2Names = { "",
                                               "",
                                               "",
                                               "",
                                               "",
                                               "",  // Progressive Bow
                                               "Silver Bow",
                                               "Bow" };

void nameForRandomizerItems1(uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(randomizerItems1Names, notify, old, new); }
void nameForRandomizerItems2(uint16 old, uint16 new, NotifyItemReceived @notify) { notifyBitfieldItem(randomizerItems2Names, notify, old, new); }

// X-Fusion (mxf) sm_events flag notifications -- see update_sm_events() in
// LocalGameState.as, which only consults these when rom.is_mxf() is true.

// value (not bit!) -> area name for 7ED820, X-Fusion's "current area" byte:
const array<string> @mxfAreaNames = { "MDK", "SRX", "TRO", "PYR", "AQA", "ARC", "NOC", "DMX" };

// index (0x00-0x11) -> display name for a major item, as written into either the
// Core-X reward table or a shuffled major-item PLM's arg high byte -- see
// mxf_corex_item_name()/mxf_plm_item_name() below and ../mxf-item-rando's
// mxf_data_bundle.json data.items.upgradeItems, which this list's order matches.
const array<string> @mxfMajorItemNames = {
  "Morph Ball", "Bombs", "Charge Beam", "Super Jump", "Super Missile", "Grapple Beam",
  "Speed Booster", "Wide Beam", "Varia Suit", "Ice Missile", "Space Jump", "Spike Breaker",
  "Plasma", "Gravity Suit", "Wave Beam", "Screw Attack", "Diffusion Missile", "Lv.2 Speed Booster",
};

// special (non-index) values written into the Core-X reward table / a major-item PLM's
// arg high byte, instead of an index into mxfMajorItemNames:
const uint16 MxfRewardArg_Nothing  = 0xF0;
const uint16 MxfRewardArg_ETank    = 0xF1; // Core-X table only; PLMs use a dedicated type instead
const uint16 MxfRewardArg_Missile  = 0xF2; // Core-X table only; PLMs use a dedicated type instead
const uint16 MxfRewardArg_PowerBomb = 0xF3; // Core-X table only; PLMs use a dedicated type instead
const uint16 MxfRewardArg_ReserveX = 0xF4;

// resolves a raw reward value (from either the Core-X table, which stores it directly,
// or a major-item PLM's arg high byte, which uses the same low byte of these F0-F4
// constants) to a display name.
string mxf_reward_item_name(uint16 v) {
  if (v == MxfRewardArg_Nothing)   return "Nothing";
  if (v == MxfRewardArg_ETank)     return "E-Tank";
  if (v == MxfRewardArg_Missile)   return "Missiles";
  if (v == MxfRewardArg_PowerBomb) return "PBs";
  if (v == MxfRewardArg_ReserveX)  return "Reserve-X";
  if (v < mxfMajorItemNames.length()) return mxfMajorItemNames[v];
  return "an item";
}

// X-Fusion's "Core-X Reward Lookup Table": a fixed-size table the item randomizer
// writes into, mapping each of the 25 boss/Data Room/Reserve-X locations (by a fixed
// index -- see the MxfCoreX() calls below) to whatever item that seed actually placed
// there. PC (ROM file) address 0x028000, 0x10 bytes/entry, reward value as a 16-bit
// word at the start of each entry. See ../mxf-item-rando/js/rom_patcher.js
// applyMajorItemLocationPlacements()/writeCoreXEntry()/computeCoreXRewardValue() for
// the address, layout, and encoding this mirrors.
const uint32 MxfCoreXRewardTableAddr = 0x058000; // PC 0x028000 -> LoROM bus address
const uint32 MxfCoreXRewardEntrySize = 0x10;

string mxf_corex_item_name(uint8 tableIndex) {
  uint16 v = bus::read_u16(MxfCoreXRewardTableAddr + uint32(tableIndex) * MxfCoreXRewardEntrySize);
  // the Core-X table stores expansion rewards as 0xFFF0-0xFFF4 (see
  // computeCoreXRewardValue()) rather than the bare 0xF0-0xF4 a PLM's arg byte uses:
  if (v >= 0xFFF0 && v <= 0xFFF4) return mxf_reward_item_name(uint16(v & 0xFF));
  return mxf_reward_item_name(v);
}

// PLM "type" values used for missile/PB/energy tank pickups (visible & hidden variants
// each), and the two "major item" PLM types used instead when a full item shuffle
// placed a major item at that location. See ../mxf-item-rando/js/rom_patcher.js
// getExpansionPlmType()/writePLMDataPC() for the values this mirrors. A PLM is 8 bytes
// -- [X:2][Y:2][type:2][arg:2] -- and our stored address points at the type field.
const uint16 MxfPlmType_MissileTank         = 0x8A3E;
const uint16 MxfPlmType_MissileTankHidden   = 0x8A4A;
const uint16 MxfPlmType_EnergyTank          = 0x8A3A;
const uint16 MxfPlmType_EnergyTankHidden    = 0x8A46;
const uint16 MxfPlmType_PowerBombTank       = 0x8A42;
const uint16 MxfPlmType_PowerBombTankHidden = 0x8A4E;
const uint16 MxfPlmType_MajorItem           = 0xD5A4;
const uint16 MxfPlmType_MajorItemHidden     = 0xD5A8;

// resolves the item actually configured at a tank/expansion PLM address, whether it's
// still an expansion tank or was shuffled into a major item. Returns "" if the PLM type
// isn't one we recognize, so the caller can fall back to plain location text.
string mxf_plm_item_name(uint32 plmAddr) {
  uint16 plmType = bus::read_u16(plmAddr);
  if (plmType == MxfPlmType_MissileTank || plmType == MxfPlmType_MissileTankHidden) return "Missiles";
  if (plmType == MxfPlmType_EnergyTank || plmType == MxfPlmType_EnergyTankHidden) return "E-Tank";
  if (plmType == MxfPlmType_PowerBombTank || plmType == MxfPlmType_PowerBombTankHidden) return "PBs";
  if (plmType == MxfPlmType_MajorItem || plmType == MxfPlmType_MajorItemHidden) {
    uint16 arg = bus::read_u16(plmAddr + 4);
    return mxf_reward_item_name(uint16(arg >> 8));
  }
  return "";
}

// one entry in the table below: sm_events[idx] bit `bit`, newly set -> notify(...).
// `text` is either the complete notification text (MxfStatic), or a "<Location>"/
// "Defeated <Boss>" prefix that gets " -- <actual item>" appended at notify time, read
// live from the ROM so it reflects the real seed rather than a hardcoded vanilla guess
// (MxfCoreX for the 25 boss/Data Room/Reserve-X locations, MxfPlm for everything else).
class MxfFlagNote {
  int idx;
  uint8 bit;
  string text;
  int coreXIndex; // >=0: resolve via mxf_corex_item_name()
  uint32 plmAddr;  // >0: resolve via mxf_plm_item_name()
  // some of these WRAM bits appear to get toggled back off by the game itself under
  // conditions we don't fully understand (rather than staying permanently set once
  // collected, as the "game flag" framing implies) -- seen in practice as the same
  // pickup notifying repeatedly. Latching per-entry once we've notified for it, rather
  // than trusting the WRAM bit to stay set, makes each one fire at most once per
  // session regardless of what the underlying byte does afterward.
  bool notified = false;

  MxfFlagNote(int idx, uint8 bit, const string &in text, int coreXIndex, uint32 plmAddr) {
    this.idx = idx;
    this.bit = bit;
    this.text = text;
    this.coreXIndex = coreXIndex;
    this.plmAddr = plmAddr;
  }
}

MxfFlagNote@ MxfStatic(int idx, uint8 bit, const string &in text) {
  return MxfFlagNote(idx, bit, text, -1, 0);
}
MxfFlagNote@ MxfCoreX(int idx, uint8 bit, const string &in text, int coreXIndex) {
  return MxfFlagNote(idx, bit, text, coreXIndex, 0);
}
MxfFlagNote@ MxfPlm(int idx, uint8 bit, const string &in text, uint32 plmAddr) {
  return MxfFlagNote(idx, bit, text, -1, plmAddr);
}

// "a"/"an" for a vowel-leading item name; "" for names that don't take an indefinite
// article at all (a plural, or "Nothing").
// the full notification text for a note, resolving a live item lookup if it has one:
// "Got <item> (<location>)" for a resolved item (no article -- kept short for screen
// space, e.g. "Got PBs (Wrecked Storage)"), else just the location/story text.
string mxf_flag_note_text(MxfFlagNote@ note) {
  string item;
  if (note.coreXIndex >= 0) {
    item = mxf_corex_item_name(uint8(note.coreXIndex));
  } else if (note.plmAddr != 0) {
    item = mxf_plm_item_name(note.plmAddr);
  } else {
    return note.text;
  }
  if (item.length() == 0) return note.text; // unrecognized item state; fall back to plain location text

  // the missile ladder is progressive (Super -> Ice -> Diffusion) rather than a
  // one-off pickup, so phrase it as an upgrade like the sword/shield/glove tiers do:
  if (item == "Super Missile" || item == "Ice Missile" || item == "Diffusion Missile") {
    return "Upgraded to " + item + " (" + note.text + ")";
  }

  return "Got " + item + " (" + note.text + ")";
}

// Every X-Fusion sm_events bit we notify on: Etecoons saved, Aux Power Cells,
// Talking-to-Adam hints, boss Core-X kills, and every individually-flagged item pickup
// (missile/PB/energy tanks, Reserve-X tanks, and Data Room downloads -- the randomizer
// shuffles what's found at each of these locations same as anything else, so we read
// the real placed item live rather than hardcode the vanilla one). `idx` is the
// sm_events[] array index (see GameState.as for how WRAM addresses map to it); location/
// boss text is taken verbatim from ../mxf-json-data's items.json (gameFlags.boss /
// gameFlags.item), cross-verified against every row having a real captured timestamp in
// docs/Super Metroid_ X-Fusion - Game Flags Documentation. Core-X table indices are
// from ../mxf-item-rando/js/rom_patcher.js's locationToCoreXIndex; PLM addresses are
// from ../mxf-item-rando/mxf_data_bundle.json's room node data (converted from PC/file
// offset to a LoROM bus address). Neo-Crocomire has no Core-X reward -- it's simply
// "Defeated", unlike the other boss kills which all grant an item.
const array<MxfFlagNote@> @mxfFlagNotes = {
  MxfCoreX(8, 0, "Defeated Yakuza", 0xa),
  MxfCoreX(9, 0, "Defeated Spikespawn", 0xb),
  MxfCoreX(9, 2, "Defeated Arachnus-X", 0x0),
  MxfCoreX(10, 0, "Defeated Nettori", 0xc),
  MxfCoreX(10, 1, "Defeated Zazabi", 0x3),
  MxfCoreX(11, 0, "Defeated Neo-Ridley", 0xf),
  MxfCoreX(11, 1, "Defeated Phantomire", 0x5),
  MxfCoreX(12, 0, "Defeated Meta Draygon-X", 0x11),
  MxfCoreX(12, 1, "Defeated Serris", 0x6),
  MxfCoreX(13, 0, "Defeated X-B.O.X.", 0xe),
  MxfCoreX(13, 1, "Defeated ARC Navigation Room's Core-X", 0x7),
  MxfCoreX(14, 0, "Defeated Nightmare", 0xd),
  MxfCoreX(14, 1, "Defeated Barrier Core-X", 0x8),
  MxfCoreX(1, 3, "SRX Data Room", 0x1),
  MxfCoreX(1, 4, "TRO Data Room", 0x2),
  MxfCoreX(1, 5, "PYR Data Room", 0x4),
  MxfCoreX(1, 6, "ARC Data Room", 0x9),
  MxfCoreX(1, 7, "AQA Data Room", 0x10),
  MxfCoreX(8, 7, "Docking Bay", 0x12),
  MxfCoreX(9, 7, "Just Don't Die Bend", 0x13),
  MxfCoreX(10, 7, "TRO Reserve X Room", 0x14),
  MxfCoreX(11, 7, "Boiler Room", 0x15),
  MxfCoreX(12, 7, "AQA Reserve X Room", 0x16),
  MxfCoreX(13, 7, "ARC Reserve X Room", 0x17),
  MxfCoreX(14, 7, "NOC Reserve X Room", 0x18),
  MxfStatic(11, 2, "Defeated Neo-Crocomire"),
  MxfStatic(2, 1, "Etecoon Saved (SRX)"),
  MxfStatic(2, 2, "Etecoon Saved (TRO)"),
  MxfStatic(2, 3, "Etecoon Saved (PYR)"),
  MxfStatic(2, 4, "Etecoon Saved (AQA)"),
  MxfStatic(2, 5, "Etecoon Saved (ARC)"),
  MxfStatic(2, 6, "Etecoon Saved (NOC)"),
  MxfStatic(2, 7, "Etecoon Saved (MDK)"),
  MxfStatic(6, 1, "Got Aux Power Cell (SRX)"),
  MxfStatic(6, 2, "Got Aux Power Cell (TRO)"),
  MxfStatic(6, 3, "Got Aux Power Cell (PYR)"),
  MxfStatic(6, 4, "Got Aux Power Cell (AQA)"),
  MxfStatic(6, 6, "Got Aux Power Cell (NOC)"),
  MxfStatic(20, 0, "Got a Hint from Adam (MDK)"),
  MxfStatic(20, 1, "Got a Hint from Adam (SRX)"),
  MxfStatic(20, 2, "Got a Hint from Adam (TRO)"),
  MxfStatic(20, 3, "Got a Hint from Adam (PYR)"),
  MxfStatic(20, 4, "Got a Hint from Adam (PYR-Ridley)"),
  MxfStatic(20, 5, "Got a Hint from Adam (AQA)"),
  MxfStatic(20, 7, "Got a Hint from Adam (NOC)"),
  MxfPlm(21, 1, "MDK-AQA Elevator Cache", 0xfd2d7),
  MxfPlm(21, 2, "Nexus Storage", 0xfd339),
  MxfPlm(21, 3, "Habitation Deck", 0xfd3cb),
  MxfPlm(21, 4, "Habitation Deck", 0xfd3d1),
  MxfPlm(21, 5, "Wrecked Storage", 0xfd3e1),
  MxfPlm(21, 6, "Ventilation Speedway", 0xfd3f1),
  MxfPlm(21, 7, "Operations Ventilation", 0xfd401),
  MxfPlm(22, 0, "Operations Ventilation", 0xfd407),
  MxfPlm(22, 1, "Crew Quarters", 0xfd415),
  MxfPlm(22, 2, "Docking Bay Supply Room", 0xfd44d),
  MxfPlm(22, 3, "Central Reactor Core", 0xfd45d),
  MxfPlm(22, 4, "Silo Scaffolding", 0xfd46d),
  MxfPlm(23, 0, "Moto Towerway", 0xfd5c5),
  MxfPlm(23, 1, "SRX Entrance Lobby", 0xfd5e7),
  MxfPlm(23, 2, "Hornoad Hole", 0xfd609),
  MxfPlm(23, 3, "Fool's Dead End", 0xfd661),
  MxfPlm(23, 4, "Lava Horseshoe", 0xfd699),
  MxfPlm(23, 5, "Lava Lake", 0xfd6bd),
  MxfPlm(23, 6, "SRX-NOC Elevator Access", 0xfd72d),
  MxfPlm(23, 7, "Searpent's Coil", 0xfd6f9),
  MxfPlm(24, 0, "Vacuum Verge", 0xfd701),
  MxfPlm(25, 0, "TRO Entrance Lobby Storage", 0xfd75d),
  MxfPlm(25, 1, "Crumble Crossing", 0xfd96d),
  MxfPlm(25, 2, "Puyo Palace", 0xfd787),
  MxfPlm(25, 3, "Reo Courtyard", 0xfd7a7),
  MxfPlm(25, 4, "TRO-PYR Access", 0xfd7af),
  MxfPlm(25, 5, "Crumble City", 0xfd7cb),
  MxfPlm(25, 6, "Crumble City", 0xfd7c5),
  MxfPlm(25, 7, "Cultivation Station", 0xfd7df),
  MxfPlm(26, 0, "Owtch Office", 0xfd7f3),
  MxfPlm(26, 1, "Zazabi Arena Access", 0xfd82b),
  MxfPlm(26, 2, "Zazabi Speedway", 0xfd859),
  MxfPlm(26, 3, "Overgrown Cache", 0xfd867),
  MxfPlm(26, 4, "Oasis Storage", 0xfd8a9),
  MxfPlm(26, 5, "Thornvault", 0xfd909),
  MxfPlm(26, 6, "Needlepoint", 0xfd955),
  MxfPlm(27, 0, "Garbage Chute", 0xfda03),
  MxfPlm(27, 1, "Garbage Chute", 0xfda09),
  MxfPlm(27, 2, "Sova Processing Access", 0xfda11),
  MxfPlm(27, 3, "Sova Processing", 0xfda1f),
  MxfPlm(27, 4, "Bob's Abode", 0xfda33),
  MxfPlm(27, 5, "Overthinking Chamber", 0xfda55),
  MxfPlm(27, 6, "Big Red Maintenance Storage", 0xfda69),
  MxfPlm(27, 7, "Big Red Maintenance Storage", 0xfda6f),
  MxfPlm(28, 0, "Geron's Treasure", 0xfdab1),
  MxfPlm(28, 1, "PYR-MDK Access", 0xfdae9),
  MxfPlm(28, 2, "Hot Potato", 0xfdafd),
  MxfPlm(28, 3, "Bubble Storage", 0xfdb1b),
  MxfPlm(28, 4, "Elevator to Neo-Ridley", 0xfdb8b),
  MxfPlm(28, 5, "PYR Security Room Access", 0xfdc43),
  MxfPlm(29, 0, "Reservoir East", 0xfdc83),
  MxfPlm(29, 1, "Reservoir Vault", 0xfdc91),
  MxfPlm(29, 2, "Hydrospark", 0xfdca9),
  MxfPlm(29, 3, "AQA Mimic Colony", 0xfdce9),
  MxfPlm(29, 4, "Owtch Corridor", 0xfdcf1),
  MxfPlm(29, 5, "Broken Bridge", 0xfdd19),
  MxfPlm(29, 6, "Buoyant Bridge", 0xfdd29),
  MxfPlm(29, 7, "Drowned Junction", 0xfdd6b),
  MxfPlm(30, 0, "Cheddar Bay", 0xfdd79),
  MxfPlm(30, 1, "Cheddar Bay", 0xfddb1),
  MxfPlm(30, 2, "Gamepad Room", 0xfddcf),
  MxfPlm(30, 3, "Skree Firing Range", 0xfddd7),
  MxfPlm(30, 4, "Serris Speedway", 0xfde0d),
  MxfPlm(30, 5, "Sunken Treasury", 0xfde71),
  MxfPlm(31, 0, "Weapons Testing Grounds", 0xfdeed),
  MxfPlm(31, 1, "Gerubus Gully", 0xfdf43),
  MxfPlm(31, 2, "ARC-PYR Access", 0xfdf51),
  MxfPlm(31, 3, "Crow's Nest", 0xfdf5f),
  MxfPlm(31, 4, "Zeela Speedway Cache", 0xfdfb7),
  MxfPlm(31, 5, "Frostbite Nook", 0xfdff1),
  MxfPlm(31, 6, "Frostbite Hall", 0xfdfeb),
  MxfPlm(31, 7, "Frozen Tower", 0xfdfff),
  MxfPlm(32, 0, "Transmutation Trial", 0xfe00b),
  MxfPlm(32, 1, "Cryopipe", 0xfe04b),
  MxfPlm(32, 2, "Arctic Gauntlet", 0xfe053),
  MxfPlm(32, 3, "Freezer Shaft West", 0xfe09f),
  MxfPlm(33, 0, "Mochtroid Tower Closet", 0xfe14b),
  MxfPlm(33, 1, "Stabilizer Shaft", 0xfe153),
  MxfPlm(33, 2, "Ripper Tower", 0xfe185),
  MxfPlm(33, 3, "Ripper Tower", 0xfe18b),
  MxfPlm(33, 4, "Pillar Highway", 0xfe1ad),
  MxfPlm(33, 5, "NOC Entrance Lobby South", 0xfe1c3),
  MxfPlm(33, 6, "NOC Mimic Lodge", 0xfe1d9),
  MxfPlm(33, 7, "Ice-X Shaft", 0xfe1ed),
  MxfPlm(34, 1, "Shiverclimb", 0xfe1b5),
  MxfPlm(34, 2, "Nocturnal Crossroads", 0xfe27b),
  // Security Room doors unlocking, and SA-X encounters ending -- the two mxf event
  // types worth surfacing to the player even though most sm_events bits sync silently.
  MxfStatic(4, 3, "SA-X Encounter Finished (Crum-Ball Tower)"),
  MxfStatic(4, 4, "SA-X Chase Over (Turbo Tunnel)"),
  MxfStatic(5, 0, "SA-X Encounter Finished (Underpressure)"),
  MxfStatic(15, 0, "SA-X True Form Destroyed"),
  MxfStatic(53, 4, "Security Doors Unlocked (MDK)"),
  MxfStatic(57, 0, "Security Doors Unlocked (TRO)"),
  MxfStatic(60, 1, "Security Doors Unlocked (PYR)"),
  MxfStatic(61, 3, "Security Doors Unlocked (AQA North)"),
  MxfStatic(61, 6, "Security Doors Unlocked (AQA South)"),
  MxfStatic(62, 2, "Security Doors Unlocked (AQA East)"),
  MxfStatic(63, 6, "Security Doors Unlocked (ARC)"),
};

// clears every entry's notified latch; called from LocalGameState::reset() so a script
// reload (or a manual reset from the settings window) starts fresh rather than staying
// permanently silenced for the rest of the emulator session.
void mxf_reset_flag_notifications() {
  // LocalGameState::reset() calls this as early as cartridge_loaded(), which can fire
  // before this file's own global initializer for mxfFlagNotes has finished -- the
  // array itself can exist (non-null) while its individual elements are still
  // default-null handles pending their own constructor calls, so guard both.
  if (mxfFlagNotes is null) return;
  for (uint n = 0; n < mxfFlagNotes.length(); n++) {
    if (mxfFlagNotes[n] is null) continue;
    mxfFlagNotes[n].notified = false;
  }
}
