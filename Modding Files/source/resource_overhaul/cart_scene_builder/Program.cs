using System.Text.Json;
using Shared.GameFormats.Esf;

// Reuse the rigid donor and ESF writer; only the position/yaw curves and their manifest change.
var source = Path.GetFullPath(args[0]);
var output = Path.GetFullPath(args[1]);
EsfNode U(uint n) => EsfNode.Leaf(EsfNodeKind.U32, n, true);
EsfNode I(int n) => EsfNode.Leaf(EsfNodeKind.I32, n, true);
EsfNode F(float n) => EsfNode.Leaf(EsfNodeKind.F32, n);
EsfNode S(string s) => EsfNode.Leaf(EsfNodeKind.Ascii, s);
EsfNode B(bool v) => EsfNode.Leaf(EsfNodeKind.Bool, v, true);
var half = 0.7713623046875f / 2;
var lane = 0.24f;
for (var turn = 0; turn < 8; turn++)
{
    var doc = EsfReader.ReadFile(source);
    var original = doc.Root.Children.First(n => n.Name == "ELEMENT");
    var fields = original.Children.Take(6).ToList();
    var angle = turn * MathF.PI / 3;
    if (angle > MathF.PI) angle -= MathF.PI * 2;
    var ax = -MathF.Sin(angle) * half;
    var az = -MathF.Cos(angle) * half;
    var samples = Enumerable.Range(0, 21).Select(i =>
    {
        var t = i / 20f;
        var x = (1 - t) * (1 - t) * ax;
        var z = (1 - t) * (1 - t) * az + t * t * half;
        var yaw = turn == 3 ? angle * (1 - t) : MathF.Atan2(-(1 - t) * ax, -(1 - t) * az + t * half);
        if (turn==6) { x=0; z=(1-t)*half; yaw=MathF.PI; }
        if (turn==7) { x=0; z=t*half; yaw=0; }
        // A 120-degree inside bend is narrower than the cart lane; taper it without a cusp.
        var width=turn is 2 or 4 ? lane*(1-MathF.Pow(MathF.Sin(t*MathF.PI),2)*2/3) : lane;
        x+=MathF.Cos(yaw)*width;
        z-=MathF.Sin(yaw)*width;
        return (t, x, z, yaw);
    }).ToArray();
    if (turn==0 && samples.Any(v=>MathF.Abs(v.x-0.24f)>0.00001f))
        throw new Exception("Straight carts must keep 0.24 display units to the right of their route");
    if (turn==6 && samples.Any(v=>MathF.Abs(v.x+lane)>0.00001f))
        throw new Exception("Arrival half-edges must join the incoming lane");
    if (turn!=3)
        for (var i=1;i<samples.Length;i++)
        {
            var a=samples[i-1];var b=samples[i];var yaw=(a.yaw+b.yaw)/2;
            if ((b.x-a.x)*MathF.Sin(yaw)+(b.z-a.z)*MathF.Cos(yaw)<=0)
                throw new Exception("A lane curve folded backward at a sharp bend");
        }
    void Channel(float initial, float[]? values = null)
    {
        fields.AddRange([F(initial), S("constant"), S("constant"), U((uint)(values?.Length ?? 0))]);
        if (values == null) return;
        for (var i = 0; i < values.Length; i++)
            fields.AddRange([F(samples[i].t), F(values[i]), S("linear"),
                EsfNode.Leaf(EsfNodeKind.Coord2d, new Coord2d(0, 0)),
                EsfNode.Leaf(EsfNodeKind.Coord2d, new Coord2d(0, 0)), S("linear")]);
    }
    fields.Add(U(1));
    Channel(0, samples.Select(v => v.x).ToArray());
    var heightField=fields.Count;
    Channel(0); Channel(0, samples.Select(v => v.z).ToArray());
    fields.Add(U(1));
    Channel(0);
    var yawField=fields.Count;
    Channel(0, samples.Select(v => v.yaw).ToArray()); Channel(0);
    fields.Add(U(1));
    var scaleField=fields.Count;
    Channel(2);
    fields.Add(U(1)); Channel(1);
    fields.AddRange(original.Children.TakeLast(3));
    var element = EsfNode.NewRecord(original.Name!, original.Version, original.RecordFlags, [fields]);
    var manifest = new List<EsfNode> { I(1), U(0), I(4) };
    var index = 0;
    foreach (var channels in new[] { 3, 3, 1, 1 })
    {
        manifest.Add(I(channels));
        for (var k = 0; k < channels; k++, index++)
        {
            var count = index is 0 or 2 or 4 ? samples.Length : 0;
            manifest.AddRange([B(false), I(count)]);
            for (var j = 0; j < count; j++) manifest.Add(B(true));
        }
    }
    manifest.AddRange([I(1), S(""), B(false), I(0), I(0), I(0), I(1), I(0), I(0)]);
    var tail = doc.Root.Children.First(n => n.Name == "COMPOSITE_SCENE");
    var root = doc.Root.Children.Take(10).ToList();
    root.AddRange([U(1), S("model"), element, doc.Root.Children.First(n => n.Name == "MODEL_ELEMENT"),
        U(1), U(uint.MaxValue), U(1), U(0), doc.Root.Children.First(n => n.Name == "ATTACH_TO_PARAMETERS"),
        EsfNode.NewRecord(tail.Name!, tail.Version, tail.RecordFlags, [manifest])]);
    var result = new EsfDocument { Signature=doc.Signature, Unknown1=doc.Unknown1, CreationDate=doc.CreationDate,
        Root=EsfNode.NewRecord(doc.Root.Name!, doc.Root.Version, doc.Root.RecordFlags, [root]) };
    var name = Path.Combine(output, $"route_cart_curve_{turn}.csc");
    EsfWriter.WriteFile(result, name);
    var check = EsfReader.ReadFile(name);
    if (check.Root.Children.Count(n => n.Name == "MODEL_ELEMENT") != 1 ||
        check.Root.Children.Any(n => n.Name is "ANIMATION_ELEMENT" or "SFX_ELEMENT"))
        throw new Exception("Rigid cart validation failed");
    Console.WriteLine(name);
    // A second scene shares the cart's translation, with a camera-facing resource sprite above it.
    fields[heightField]=F(0.9f);
    fields[scaleField]=F(1);
    var iconRoot=root.ToList();
    iconRoot[11]=S("vfx");
    iconRoot[12]=EsfNode.NewRecord(original.Name!,original.Version,original.RecordFlags,[fields]);
    var donor=EsfReader.ReadFile(args[2]);
    var vfx=donor.Root.Children.First(n=>n.Name=="VFX_ELEMENT");
    iconRoot[13]=EsfNode.NewRecord(vfx.Name!,vfx.Version,vfx.RecordFlags,[[S("derpy_mr_cart_icon_placeholder"),B(true)]]);
    var icon=new EsfDocument{Signature=result.Signature,Unknown1=result.Unknown1,CreationDate=result.CreationDate,
        Root=EsfNode.NewRecord(result.Root.Name!,result.Root.Version,result.Root.RecordFlags,[iconRoot])};
    EsfWriter.WriteFile(icon,Path.Combine(output,$"route_icon_curve_{turn}.csc"));
    // Ocean models and icons sit on the water plane, not the seabed.
    fields[5]=S("free");
    fields[heightField]=F(0);
    fields[scaleField]=F(0.22f);
    var boatRoot=root.ToList();
    boatRoot[12]=EsfNode.NewRecord(original.Name!,original.Version,original.RecordFlags,[fields]);
    var model=doc.Root.Children.First(n=>n.Name=="MODEL_ELEMENT");
    var boatModel=model.Children.ToList();
    boatModel[0]=S("rigidmodels/derpy_mr_trade_boat.rigid_model_v2");
    boatRoot[13]=EsfNode.NewRecord(model.Name!,model.Version,model.RecordFlags,[boatModel]);
    EsfWriter.WriteFile(new EsfDocument{Signature=result.Signature,Unknown1=result.Unknown1,CreationDate=result.CreationDate,
        Root=EsfNode.NewRecord(result.Root.Name!,result.Root.Version,result.Root.RecordFlags,[boatRoot])},
        Path.Combine(output,$"route_boat_curve_{turn}.csc"));
    fields[heightField]=F(0.9f);
    fields[scaleField]=F(1);
    iconRoot[12]=EsfNode.NewRecord(original.Name!,original.Version,original.RecordFlags,[fields]);
    var seaIcon=new EsfDocument{Signature=result.Signature,Unknown1=result.Unknown1,CreationDate=result.CreationDate,
        Root=EsfNode.NewRecord(result.Root.Name!,result.Root.Version,result.Root.RecordFlags,[iconRoot])};
    EsfWriter.WriteFile(seaIcon,Path.Combine(output,$"route_sea_icon_curve_{turn}.csc"));
    var vehicleManifest=Path.Combine(output,"trade_vehicle_manifest.json");
    if (File.Exists(vehicleManifest))
    {
        using var vehicles=JsonDocument.Parse(File.ReadAllText(vehicleManifest));
        foreach (var vehicle in vehicles.RootElement.EnumerateObject())
        {
            var entry=vehicle.Value;
            fields[5]=S(entry.GetProperty("sea").GetBoolean()?"free":"map_zero_y_to_terrain");
            fields[heightField]=F(entry.GetProperty("height").GetSingle());
            fields[scaleField]=F(entry.GetProperty("scale").GetSingle());
            // The prop's own facing turns every yaw key; position keys stay on the lane.
            var vehicleFields=fields.ToList();
            var turnYaw=entry.GetProperty("yaw").GetSingle();
            for (var i=0;i<samples.Length;i++)
            {
                var key=yawField+4+i*6;
                if ((float)vehicleFields[key].Value! != samples[i].t || (float)vehicleFields[key+1].Value! != samples[i].yaw)
                    throw new Exception("Vehicle yaw offset missed the yaw keys");
                if (turnYaw!=0) vehicleFields[key+1]=F(samples[i].yaw+turnYaw);   // -0 + 0 would rewrite the sign byte
            }
            var vehicleRoot=root.ToList();
            vehicleRoot[12]=EsfNode.NewRecord(original.Name!,original.Version,original.RecordFlags,[vehicleFields]);
            var vehicleModel=model.Children.ToList();
            vehicleModel[0]=S(entry.GetProperty("model").GetString()!);
            vehicleRoot[13]=EsfNode.NewRecord(model.Name!,model.Version,model.RecordFlags,[vehicleModel]);
            EsfWriter.WriteFile(new EsfDocument{Signature=result.Signature,Unknown1=result.Unknown1,CreationDate=result.CreationDate,
                Root=EsfNode.NewRecord(result.Root.Name!,result.Root.Version,result.Root.RecordFlags,[vehicleRoot])},
                Path.Combine(output,$"route_vehicle_{vehicle.Name}_{turn}.csc"));
        }
    }

}
